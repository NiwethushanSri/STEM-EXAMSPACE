import { type AppRole, requireCaller, serviceClient } from "../_shared/auth.ts";
import { HttpError, handle, jsonResponse } from "../_shared/errors.ts";
import { writeAudit } from "../_shared/audit.ts";
import { clearInviteToken, provisionInvitedUser, sendInviteEmail } from "../_shared/invite.ts";

const ROLES: AppRole[] = ["owner", "admin", "teacher", "tutor", "corrector", "student", "parent"];
const MAY_INVITE: Record<string, AppRole[]> = {
  owner: ["admin", "teacher", "tutor", "corrector"],
  admin: ["teacher", "tutor", "corrector"],
};
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function name(v: unknown, label: string): string {
  const s = typeof v === "string" ? v.trim() : "";
  if (s.length === 0 || s.length > 80) {
    throw new HttpError("invalid_input", 400, `${label} must be 1 to 80 characters.`);
  }
  return s;
}

const IN_USE = () => new HttpError("email_in_use", 409, "An account with this email already exists.");

Deno.serve(handle(async (req) => {
  if (req.method !== "POST") throw new HttpError("invalid_input", 405, "Use POST.");
  const caller = await requireCaller(req, ["owner", "admin"]);

  let body: Record<string, unknown>;
  try {
    const parsed = await req.json();
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("shape");
    body = parsed as Record<string, unknown>;
  } catch {
    throw new HttpError("invalid_input", 400, "Invalid request body.");
  }

  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  if (email.length > 254 || !EMAIL.test(email)) throw new HttpError("invalid_input", 400, "Enter a valid email address.");
  const firstName = name(body.firstName, "First name");
  const lastName = name(body.lastName, "Last name");
  const role = body.role as AppRole;
  if (typeof role !== "string" || !ROLES.includes(role)) throw new HttpError("invalid_input", 400, "Unknown role.");
  if (!(MAY_INVITE[caller.role] ?? []).includes(role)) {
    throw new HttpError("forbidden", 403, "You do not have permission to invite this role.");
  }

  const svc = serviceClient();
  const { data: existing, error: eErr } = await svc.from("profiles").select("id").eq("email", email).maybeSingle();
  if (eErr) throw new Error(`email lookup failed: ${eErr.code ?? "unknown"}`);
  if (existing) throw IN_USE();

  // A fresh token every time: a stale invite for this email must not stay claimable.
  const { data: invite, error: iErr } = await svc.from("pending_invites")
    .upsert({ email, role, invited_by: caller.id, token: crypto.randomUUID() }, { onConflict: "email" })
    .select("token").single();
  if (iErr || !invite) {
    console.error("invite insert failed:", iErr?.code ?? "unknown");
    throw new HttpError("internal", 500, "Something went wrong. Please try again.");
  }

  const res = await provisionInvitedUser(svc, { email, token: invite.token, role, firstName, lastName });
  if (!res.userId) {
    if (res.warning === "email_in_use") throw IN_USE();
    throw new HttpError("internal", 500, "Could not create the invitation. Please try again.");
  }

  let emailSent = false;
  if (res.invited) {
    await clearInviteToken(svc, res.userId);
    emailSent = await sendInviteEmail(svc, res.userId, email);
  }
  await writeAudit(caller.id, "staff_invited", "profile", res.userId);
  return jsonResponse({ invited: true, emailSent });
}));
