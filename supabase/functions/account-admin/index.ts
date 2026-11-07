import { type AppRole, requireCaller, serviceClient } from "../_shared/auth.ts";
import { HttpError, handle, jsonResponse } from "../_shared/errors.ts";
import { writeAudit } from "../_shared/audit.ts";
import {
  clearInviteToken,
  linkParent,
  provisionInvitedUser,
  reserveInvite,
  sendInviteEmail,
} from "../_shared/invite.ts";
import type { SupabaseClient } from "@supabase/supabase-js";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface Target {
  id: string;
  role: AppRole;
  status: string;
  email: string;
  invite_sent_at: string | null;
}

/** A response plus whether a committed effect happened (only then is it audited). */
interface Outcome {
  response: Response;
  audit: boolean;
}

const CONFLICT = (m: string) => new HttpError("conflict", 409, m);

function parentEmailIsStaff(detail: "student" | "staff"): HttpError {
  return new HttpError(
    "parent_email_is_staff",
    409,
    detail === "student"
      ? "The parent email belongs to a student account. Edit the parent email first."
      : "The parent email belongs to a staff account. Edit the parent email first.",
  );
}

/** (a) Re-sends the invite to an invited staff or parent account that never received it. */
async function resendStaffInvite(svc: SupabaseClient, callerRole: AppRole, t: Target): Promise<Outcome> {
  if (callerRole !== "owner" && (t.role === "owner" || t.role === "admin")) {
    throw new HttpError("forbidden", 403, "You do not have permission to do this.");
  }
  if (t.status !== "active") throw CONFLICT("This account is not active.");
  if (t.invite_sent_at !== null) throw CONFLICT("This invitation was already sent.");
  const sent = await sendInviteEmail(svc, t.id, t.email);
  return { response: jsonResponse({ emailSent: sent }), audit: sent };
}

/** (b) Rebuilds the parent invite for an approved student that has no parent link. */
async function resendParentInvite(svc: SupabaseClient, actorId: string, t: Target): Promise<Outcome> {
  const { data: det } = await svc.from("student_details")
    .select("index_number, signup_parent_name, signup_parent_email").eq("profile_id", t.id).maybeSingle();
  if (!det?.index_number || !["profile_incomplete", "active"].includes(t.status)) {
    throw CONFLICT("This student is not approved.");
  }
  const { count, error: cErr } = await svc.from("parent_children")
    .select("*", { count: "exact", head: true }).eq("student_id", t.id);
  if (cErr) throw new Error(`link lookup failed: ${cErr.code ?? "unknown"}`);
  if ((count ?? 0) > 0) throw CONFLICT("This student already has a parent.");

  const parentEmail = String(det.signup_parent_email ?? "").trim().toLowerCase();
  if (!parentEmail) throw CONFLICT("The student has no parent email. Edit the student first.");

  const { data: existing } = await svc.from("profiles").select("id, role, status").eq("email", parentEmail).maybeSingle();

  let parentId: string | null = null;
  let invited = false;
  let token: string | null = null;

  if (existing?.role === "parent") {
    parentId = existing.id;
  } else if (existing) {
    // Only a token-bearing parent sign-up shell (an interrupted creation) may be healed.
    const { data: pending } = await svc.from("pending_invites")
      .select("token, role").eq("email", parentEmail).maybeSingle();
    let shell = false;
    let ageMs = 0;
    if (existing.role === "student" && ["unconfirmed", "pending"].includes(existing.status) && pending?.role === "parent") {
      const { data: au } = await svc.auth.admin.getUserById(existing.id);
      shell = au?.user?.app_metadata?.invite_token === pending.token;
      ageMs = au?.user ? Date.now() - new Date(au.user.created_at).getTime() : 0;
    }
    if (!shell || !pending) throw parentEmailIsStaff(existing.role === "student" ? "student" : "staff");
    // The claim only accepts shells younger than 24 hours; an older one needs an owner to clear it.
    if (ageMs > 24 * 60 * 60 * 1000) throw CONFLICT("This parent invite is stuck. Ask an owner to remove the old invite.");
    token = pending.token;
  } else {
    const r = await reserveInvite(svc, parentEmail, "parent", actorId);
    if (r === "role_conflict") throw parentEmailIsStaff("staff");
    if (r === "error") throw new HttpError("internal", 500, "Something went wrong. Please try again.");
    token = r.token;
  }

  if (token) {
    const full = String(det.signup_parent_name ?? "").trim();
    const space = full.indexOf(" ");
    const res = await provisionInvitedUser(svc, {
      email: parentEmail,
      token,
      role: "parent",
      firstName: space === -1 ? full : full.slice(0, space),
      lastName: space === -1 ? "" : full.slice(space + 1).trim(),
    });
    parentId = res.userId;
    invited = res.invited;
    if (!parentId && res.warning === "email_in_use") throw parentEmailIsStaff("staff");
  }
  if (!parentId) throw new HttpError("internal", 500, "Something went wrong. Please try again.");

  let emailSent = false;
  const lr = await linkParent(svc, parentId, t.id);
  const linked = lr === "linked" || lr === "exists";
  if (invited) {
    await clearInviteToken(svc, parentId);
    emailSent = await sendInviteEmail(svc, parentId, parentEmail);
  }
  if (!linked && !invited) {
    // Nothing changed: report why, never audit.
    if (lr === "parent_inactive" || lr === "blocked") {
      return {
        response: jsonResponse({
          parentLinked: false,
          parentInvited: false,
          emailSent: false,
          warning: lr === "blocked" ? "link_blocked" : "parent_suspended",
        }),
        audit: false,
      };
    }
    throw new HttpError("internal", 500, "Something went wrong. Please try again.");
  }
  const body: Record<string, unknown> = { parentLinked: linked, parentInvited: invited, emailSent };
  if (lr === "parent_inactive") body.warning = "parent_suspended";
  return { response: jsonResponse(body), audit: true };
}

async function resendInvite(svc: SupabaseClient, caller: { id: string; role: AppRole }, userId: string) {
  const { data: t, error } = await svc.from("profiles")
    .select("id, role, status, email, invite_sent_at").eq("id", userId).maybeSingle();
  if (error) throw new Error(`profile lookup failed: ${error.code ?? "unknown"}`);
  if (!t) throw new HttpError("not_found", 404, "Account not found.");
  const target = t as Target;

  const out = target.role === "student"
    ? await resendParentInvite(svc, caller.id, target)
    : await resendStaffInvite(svc, caller.role, target);
  if (out.audit) await writeAudit(caller.id, "invite_resent", "profile", userId);
  return out.response;
}

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
  const userId = body.userId;
  if (typeof userId !== "string" || !UUID.test(userId)) {
    throw new HttpError("invalid_input", 400, "userId must be a valid id.");
  }

  const svc = serviceClient();
  switch (body.action) {
    case "resend_invite":
      return await resendInvite(svc, caller, userId);
    default:
      throw new HttpError("invalid_input", 400, "Unknown action.");
  }
}));
