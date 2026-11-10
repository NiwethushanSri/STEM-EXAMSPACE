import { serviceClient } from "../_shared/auth.ts";
import { HttpError, handle, jsonResponse } from "../_shared/errors.ts";
import { sendEmail } from "../_shared/email.ts";
import { buildAuthLink } from "../_shared/links.ts";
import { email as validEmail, str, validPastDate } from "../_shared/validate.ts";

const bad = (m: string) => new HttpError("invalid_input", 400, m);
const internal = () => new HttpError("internal", 500, "Something went wrong. Please try again.");

/** The one answer for a new, replaced, protected, already registered or undeliverable address, so the form never reveals which exist. */
const neutral = () => jsonResponse({ ok: true });

/** Every answer after validation and the rate limits takes this long, whatever happened, so timing reveals nothing. */
const MIN_MS = 800;
/** Used only when background work is unavailable: the slow work then runs inline and the answer is padded to this. */
const FALLBACK_MS = 2500;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

declare const EdgeRuntime: { waitUntil?: (p: Promise<unknown>) => void } | undefined;

/**
 * Public student registration (section 6.1). No password is taken here: the account is created without one and
 * the emailed link (a recovery link) confirms the address and lets the inbox owner choose the password. Whoever
 * registers an address therefore never holds a usable password for it. Unconfirmed sign-ups older than 1 hour
 * are replaced by a newer attempt; younger ones, confirmed accounts and any other kind of account are untouched.
 * Every answer after validation and the rate limits is the same 200 { ok: true } after 800 ms. The slow work
 * (look-up, createUser, generateLink, email, undo) runs in the background via EdgeRuntime.waitUntil so the
 * response time does not depend on it; without waitUntil it runs inline and the answer is padded to 2500 ms.
 * Deploy with --no-verify-jwt (the caller has no session).
 */
Deno.serve(handle(async (req) => {
  if (req.method !== "POST") throw new HttpError("invalid_input", 405, "Use POST.");
  const started = performance.now();

  let body: Record<string, unknown>;
  try {
    const parsed = await req.json();
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("shape");
    body = parsed as Record<string, unknown>;
  } catch {
    throw bad("Invalid request body.");
  }

  const firstName = str(body.firstName, 1, 80);
  const lastName = str(body.lastName, 1, 80);
  const school = str(body.school, 1, 120);
  const parentName = str(body.parentName, 1, 120);
  const email = validEmail(body.email);
  const parentEmail = validEmail(body.parentEmail);
  if (!firstName || !lastName || !school || !parentName) throw bad("Fill in every field.");
  if (!email) throw bad("Enter a valid email address.");
  if (!parentEmail) throw bad("Enter a valid parent email address.");
  if (!validPastDate(body.dateOfBirth)) throw bad("Enter a valid date of birth.");
  const dob = body.dateOfBirth;

  const svc = serviceClient();
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  // 30 per IP and 3 per email in 15 minutes, both checked before anything about the address is looked up.
  // 429 depends only on the caller's own recent attempts, so it reveals nothing about the address.
  const { data: allowed, error: beginErr } = await svc.rpc("login_attempt_begin_n", {
    p_key_a: `reg:${ip}`,
    p_key_b: `rege:${email.toLowerCase()}`,
    p_limit_a: 30,
    p_limit_b: 3,
  });
  if (beginErr) {
    console.error("login_attempt_begin_n failed:", beginErr.code ?? "unknown");
    throw internal();
  }
  if (allowed !== true) throw new HttpError("rate_limited", 429, "Too many attempts. Try again later.");

  const input: Input = { firstName, lastName, school, parentName, email, parentEmail, dob: String(dob) };
  const work = createSignup(svc, input).catch((e) => {
    // Codes only: never the address, names or the error text.
    console.error("register background failed:", e instanceof HttpError ? e.code : "unknown");
  });

  if (typeof EdgeRuntime !== "undefined" && typeof EdgeRuntime.waitUntil === "function") {
    EdgeRuntime.waitUntil(work);
    const left = MIN_MS - (performance.now() - started);
    if (left > 0) await sleep(left);
    return neutral();
  }
  // Fallback: wait for the work, but never answer before FALLBACK_MS.
  await work;
  const elapsed = performance.now() - started;
  if (elapsed > FALLBACK_MS) console.error("register inline work exceeded", FALLBACK_MS, "ms");
  else await sleep(FALLBACK_MS - elapsed);
  return neutral();
}));

type Input = {
  firstName: string;
  lastName: string;
  school: string;
  parentName: string;
  email: string;
  parentEmail: string;
  dob: string;
};

/** Creates the sign-up and emails the link. Returns normally for every outcome the caller must not tell apart. */
async function createSignup(svc: ReturnType<typeof serviceClient>, i: Input): Promise<void> {
  // An unconfirmed self sign-up older than 1 hour is replaced; anything else is untouched.
  const { data: state, error: rErr } = await svc.rpc("replace_unconfirmed_signup", { p_email: i.email });
  if (rErr) {
    console.error("replace_unconfirmed_signup failed:", rErr.code ?? "unknown");
    throw internal();
  }
  if (state === "confirmed" || state === "protected") return;
  if (state !== "none" && state !== "replaced") throw internal();

  // No password: the account cannot be signed into until the emailed link is used to choose one.
  const { data: created, error: cErr } = await svc.auth.admin.createUser({
    email: i.email,
    email_confirm: false,
    user_metadata: {
      first_name: i.firstName,
      last_name: i.lastName,
      date_of_birth: i.dob,
      school: i.school,
      parent_name: i.parentName,
      parent_email: i.parentEmail,
    },
  });
  if (cErr || !created.user) {
    // A concurrent registration for the same address won: same neutral answer.
    if (cErr && /already|registered|exists/i.test(cErr.message)) return;
    console.error("createUser failed:", cErr?.status ?? "unknown", cErr?.code ?? "unknown");
    throw internal();
  }
  const userId = created.user.id;

  // If the link cannot be made or sent, remove the account we just created (still unconfirmed, never usable)
  // so the person can simply register again. The answer stays the same either way.
  const undo = async () => {
    const { error } = await svc.auth.admin.deleteUser(userId);
    if (error) console.error("signup cleanup failed for", userId);
  };
  // A recovery link: verifying it confirms the address and signs the person in to choose their password.
  const { data: link, error: lErr } = await svc.auth.admin.generateLink({ type: "recovery", email: i.email });
  const hashed = link?.properties?.hashed_token;
  if (lErr || !hashed) {
    console.error("generateLink failed:", lErr?.status ?? "unknown", lErr?.code ?? "unknown");
    await undo();
    return;
  }
  let sent = false;
  try {
    sent = await sendEmail(i.email, "confirm_signup", {
      link: buildAuthLink(hashed, "recovery"),
      name: i.firstName,
      student_name: `${i.firstName} ${i.lastName}`,
      date_of_birth: i.dob,
      school: i.school,
      parent_email: i.parentEmail,
    });
  } catch (e) {
    console.error("confirm link failed:", e instanceof Error ? e.message : "unknown"); // e.g. SITE_URL missing
  }
  if (!sent) {
    console.error("confirm email not sent");
    await undo();
  }
}
