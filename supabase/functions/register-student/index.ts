import { serviceClient } from "../_shared/auth.ts";
import { HttpError, handle, jsonResponse } from "../_shared/errors.ts";
import { sendEmail } from "../_shared/email.ts";
import { buildAuthLink } from "../_shared/links.ts";
import { email as validEmail, str, validPastDate } from "../_shared/validate.ts";

const bad = (m: string) => new HttpError("invalid_input", 400, m);
const internal = () => new HttpError("internal", 500, "Something went wrong. Please try again.");

/** The one answer for a new, replaced or already registered address, so the form never reveals which exist. */
const neutral = () => jsonResponse({ ok: true });

/**
 * Public student registration (section 6.1). The web form calls this instead of auth.signUp so that a
 * pre-registered, still unconfirmed attempt for the same address is replaced rather than kept: whoever
 * registers an address first can no longer keep its password after the real owner registers and confirms.
 * Deploy with --no-verify-jwt (the caller has no session).
 */
Deno.serve(handle(async (req) => {
  if (req.method !== "POST") throw new HttpError("invalid_input", 405, "Use POST.");

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
  const password = body.password;
  if (!firstName || !lastName || !school || !parentName) throw bad("Fill in every field.");
  if (!email) throw bad("Enter a valid email address.");
  if (!parentEmail) throw bad("Enter a valid parent email address.");
  if (typeof password !== "string" || password.length < 8 || password.length > 200) {
    throw bad("Choose a password of 8 to 200 characters.");
  }
  if (!validPastDate(body.dateOfBirth)) throw bad("Enter a valid date of birth.");
  const dob = body.dateOfBirth;

  const svc = serviceClient();
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  const { data: allowed, error: beginErr } = await svc.rpc("login_attempt_begin", { p_ip_key: `reg:${ip}`, p_idx_key: `regx:${ip}` });
  if (beginErr) {
    console.error("login_attempt_begin failed:", beginErr.code ?? "unknown");
    throw internal();
  }
  if (allowed !== true) throw new HttpError("rate_limited", 429, "Too many attempts. Try again later.");

  // An unconfirmed self sign-up for this address is replaced; a confirmed or any other kind of account is untouched.
  const { data: state, error: rErr } = await svc.rpc("replace_unconfirmed_signup", { p_email: email });
  if (rErr) {
    console.error("replace_unconfirmed_signup failed:", rErr.code ?? "unknown");
    throw internal();
  }
  if (state === "confirmed" || state === "protected") return neutral();
  if (state !== "none" && state !== "replaced") throw internal();

  const { data: created, error: cErr } = await svc.auth.admin.createUser({
    email,
    password,
    email_confirm: false,
    user_metadata: {
      first_name: firstName,
      last_name: lastName,
      date_of_birth: dob,
      school,
      parent_name: parentName,
      parent_email: parentEmail,
    },
  });
  if (cErr || !created.user) {
    // A concurrent registration for the same address won: same neutral answer.
    if (cErr && /already|registered|exists/i.test(cErr.message)) return neutral();
    console.error("createUser failed:", cErr?.status ?? "unknown", cErr?.code ?? "unknown");
    throw internal();
  }
  const userId = created.user.id;

  // Confirmation link (verified server side by /auth/callback). If it cannot be made, remove the account
  // we just created (still unconfirmed, never used) so the person can simply register again.
  const undo = async () => {
    const { error } = await svc.auth.admin.deleteUser(userId);
    if (error) console.error("signup cleanup failed for", userId);
  };
  const { data: link, error: lErr } = await svc.auth.admin.generateLink({ type: "signup", email, password });
  const hashed = link?.properties?.hashed_token;
  if (lErr || !hashed) {
    console.error("generateLink failed:", lErr?.status ?? "unknown", lErr?.code ?? "unknown");
    await undo();
    throw internal();
  }
  let sent = false;
  try {
    sent = await sendEmail(email, "confirm_signup", { link: buildAuthLink(hashed, "signup"), name: firstName });
  } catch (e) {
    console.error("confirm link failed:", e instanceof Error ? e.message : "unknown"); // e.g. SITE_URL missing
  }
  if (!sent) {
    // Nothing was delivered, so nobody can confirm this account: do not leave it squatting on the address.
    await undo();
    throw internal();
  }
  return neutral();
}));
