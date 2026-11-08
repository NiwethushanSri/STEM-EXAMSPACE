import type { SupabaseClient } from "@supabase/supabase-js";
import { type AppRole, requireCaller, serviceClient } from "../_shared/auth.ts";
import { HttpError, handle, jsonResponse } from "../_shared/errors.ts";
import { sendEmail } from "../_shared/email.ts";
import { buildAuthLink } from "../_shared/links.ts";

const MIN_MS = 600;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const NOT_FOUND = "We could not find a child with those details";
const INTERNAL = () => new HttpError("internal", 500, "Something went wrong. Please try again.");
const bad = (m: string) => new HttpError("invalid_input", 400, m);

/** Same normalisation as index-login. */
function normaliseIndex(raw: string): string {
  let s = raw.toUpperCase().replace(/\s+/g, "");
  const m = /^SE(\d{4})(\d{4,})$/.exec(s);
  if (m) s = `SE-${m[1]}-${m[2]}`;
  return s;
}

/** A real calendar date in the past (YYYY-MM-DD). */
function validPastDate(s: unknown): s is string {
  if (typeof s !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  const d = new Date(`${s}T00:00:00Z`);
  if (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== s) return false;
  if (d.getTime() >= Date.now()) return false;
  // The child must be 8 to 25 years old today.
  const now = new Date();
  let age = now.getUTCFullYear() - d.getUTCFullYear();
  if (now.getUTCMonth() < d.getUTCMonth() || (now.getUTCMonth() === d.getUTCMonth() && now.getUTCDate() < d.getUTCDate())) age--;
  return age >= 8 && age <= 25;
}

function str(v: unknown, min: number, max: number): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t.length >= min && t.length <= max ? t : null;
}

async function beginAttempt(svc: SupabaseClient, keyA: string, keyB: string): Promise<void> {
  const { data, error } = await svc.rpc("login_attempt_begin", { p_ip_key: keyA, p_idx_key: keyB });
  if (error) {
    console.error("login_attempt_begin failed:", error.code ?? "unknown");
    throw INTERNAL();
  }
  if (data !== true) throw new HttpError("rate_limited", 429, "Too many attempts. Try again later.");
}

async function registerChild(svc: SupabaseClient, caller: { id: string }, raw: unknown): Promise<Response> {
  const c = (raw ?? {}) as Record<string, unknown>;
  const firstName = str(c.firstName, 1, 80);
  const lastName = str(c.lastName, 1, 80);
  const school = str(c.school, 1, 120);
  const email = typeof c.email === "string" ? c.email.trim().toLowerCase() : "";
  if (!firstName || !lastName || !school) throw bad("Enter the child's first name, last name and school.");
  if (email.length > 254 || !EMAIL.test(email)) throw bad("Enter a valid email address for the child.");
  if (!validPastDate(c.dateOfBirth)) throw bad("Enter a valid date of birth.");
  const dob = c.dateOfBirth;

  // Counts every registration attempt (two distinct keys so each attempt adds one row per key).
  await beginAttempt(svc, `preg:${caller.id}`, `pregx:${caller.id}`);

  const { data: me, error: meErr } = await svc.from("profiles")
    .select("first_name, last_name, email").eq("id", caller.id).maybeSingle();
  if (meErr || !me) throw INTERNAL();

  const inUse = () => new HttpError("email_in_use", 409, "An account with this email already exists.");
  const { data: existing, error: exErr } = await svc.from("profiles").select("id").eq("email", email).maybeSingle();
  if (exErr) throw INTERNAL();
  if (existing) throw inUse();
  const { data: invited, error: ivErr } = await svc.from("pending_invites").select("email").eq("email", email).maybeSingle();
  if (ivErr) throw INTERNAL();
  if (invited) throw inUse();

  const parentName = `${me.first_name ?? ""} ${me.last_name ?? ""}`.trim();
  const { data: created, error: cErr } = await svc.auth.admin.createUser({
    email,
    email_confirm: false,
    user_metadata: {
      first_name: firstName,
      last_name: lastName,
      date_of_birth: dob,
      school,
      parent_name: parentName,
      parent_email: String(me.email),
    },
  });
  if (cErr || !created.user) {
    if (cErr && /already|registered|exists/i.test(cErr.message)) throw inUse();
    console.error("createUser failed:", cErr?.status ?? "unknown", cErr?.code ?? "unknown");
    throw INTERNAL();
  }
  const childId = created.user.id;

  const { data: marked, error: mErr } = await svc.rpc("register_child_tx", { p_child: childId, p_parent: caller.id });
  if (mErr || marked !== true) {
    console.error("register_child_tx failed:", mErr?.code ?? "refused");
    // The shell was created by this request and is still unconfirmed: remove it.
    const { error: dErr } = await svc.auth.admin.deleteUser(childId);
    if (dErr) console.error("orphan child cleanup failed for", childId);
    throw INTERNAL();
  }

  // Best effort: the account exists; a missing email is reported, never fatal.
  let emailSent = false;
  const { data: link, error: lErr } = await svc.auth.admin.generateLink({ type: "recovery", email });
  if (lErr) console.error("generateLink failed:", lErr.status ?? "unknown", lErr.code ?? "unknown");
  const hashed = link?.properties?.hashed_token;
  if (hashed) {
    try {
      emailSent = await sendEmail(email, "child_confirm", { link: buildAuthLink(hashed, "recovery"), name: firstName, parent_name: parentName });
    } catch (e) {
      console.error("child link failed:", e instanceof Error ? e.message : "unknown"); // e.g. SITE_URL missing
    }
  }

  return jsonResponse({ registered: true, emailSent });
}

async function requestLink(svc: SupabaseClient, caller: { id: string }, body: Record<string, unknown>, started: number) {
  if (typeof body.indexNumber !== "string" || body.indexNumber.length === 0 || body.indexNumber.length > 40) {
    throw bad("Enter the child's index number and date of birth.");
  }
  if (!validPastDate(body.dateOfBirth)) throw bad("Enter a valid date of birth.");
  const index = normaliseIndex(body.indexNumber);
  const dob = body.dateOfBirth;

  await beginAttempt(svc, `plink:${caller.id}`, `pidx:${index}`);

  // Match and no-match take the same minimum time and give the same kind of answer shape.
  const pad = async () => {
    const left = MIN_MS - (Date.now() - started);
    if (left > 0) await new Promise((r) => setTimeout(r, left));
  };
  let matched = false;
  if (/^SE-\d{4}-\d{4,}$/.test(index)) {
    const { data, error } = await svc.rpc("request_parent_link_tx", { p_parent: caller.id, p_index: index, p_dob: dob });
    if (error) {
      console.error("request_parent_link_tx failed:", error.code ?? "unknown");
      await pad();
      throw INTERNAL();
    }
    matched = data === true;
    if (matched) {
      // The index counter counts failures only: give this successful attempt back.
      const { error: rErr } = await svc.rpc("login_attempt_refund_key", { p_key: `pidx:${index}` });
      if (rErr) console.error("login_attempt_refund_key failed:", rErr.code ?? "unknown");
    }
  }
  await pad();
  if (!matched) throw new HttpError("not_found", 404, NOT_FOUND);
  return jsonResponse({ requested: true });
}

async function decideLink(svc: SupabaseClient, caller: { id: string }, body: Record<string, unknown>, approve: boolean) {
  const id = body.requestId;
  if (typeof id !== "string" || !UUID.test(id)) throw bad("requestId must be a valid id.");
  const { data, error } = await svc.rpc("decide_parent_link_tx", { p_request: id, p_actor: caller.id, p_approve: approve });
  if (error) {
    console.error("decide_parent_link_tx failed:", error.code ?? "unknown");
    throw INTERNAL();
  }
  switch (data) {
    case "approved":
      return jsonResponse({ approved: true });
    case "rejected":
      return jsonResponse({ rejected: true });
    case "not_found":
      throw new HttpError("not_found", 404, "This link request was not found or was already handled.");
    case "conflict":
      throw new HttpError("conflict", 409, "The parent or the child is no longer eligible for this link.");
    case "forbidden":
      throw new HttpError("forbidden", 403, "You do not have permission to do this.");
    default:
      throw INTERNAL();
  }
}

Deno.serve(handle(async (req) => {
  const started = Date.now();
  if (req.method !== "POST") throw new HttpError("invalid_input", 405, "Use POST.");
  const caller = await requireCaller(req, ["parent", "owner", "admin"]);

  let body: Record<string, unknown>;
  try {
    const parsed = await req.json();
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("shape");
    body = parsed as Record<string, unknown>;
  } catch {
    throw bad("Invalid request body.");
  }

  const need = (roles: AppRole[]) => {
    if (!roles.includes(caller.role)) throw new HttpError("forbidden", 403, "You do not have permission to do this.");
  };
  const svc = serviceClient();
  switch (body.action) {
    case "register":
      need(["parent"]);
      return await registerChild(svc, caller, body.child);
    case "link":
      need(["parent"]);
      return await requestLink(svc, caller, body, started);
    case "approve_link":
    case "reject_link":
      need(["owner", "admin"]);
      return await decideLink(svc, caller, body, body.action === "approve_link");
    default:
      throw bad("Unknown action.");
  }
}));
