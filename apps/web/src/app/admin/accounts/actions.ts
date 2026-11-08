"use server";

import { revalidatePath } from "next/cache";
import {
  accountAdmin,
  approveStudent,
  inviteUser,
  messageFor,
  parentChild,
  rejectStudent,
  type AppRole,
  type ErrorCode,
  type FunctionResult,
  type StemClient,
} from "@stem/shared";
import { createClient, getSessionProfile } from "@/lib/supabase/server";
import { WARNING_TEXT } from "@/lib/account-rules";

/** What every action returns to the client; never throws for expected failures. */
export type ActionResult =
  | { ok: true; message: string; warning?: string }
  | { ok: false; code: ErrorCode; message: string };

const fail = (code: ErrorCode, message = messageFor(code)): ActionResult => ({ ok: false, code, message });

/**
 * Every action starts here: the caller must be an active owner or admin according to the database
 * (re-checked per call, never trusted from the page that rendered the button). The Edge Function then
 * enforces the finer rules again. The client carries only the user's session (anon key).
 */
async function authorised(): Promise<{ client: StemClient } | { denied: ActionResult }> {
  const me = await getSessionProfile();
  if (!me) return { denied: fail("unauthenticated") };
  if ((me.role !== "owner" && me.role !== "admin") || me.status !== "active") return { denied: fail("forbidden") };
  return { client: (await createClient()) as unknown as StemClient };
}

/**
 * `registration` marks the approve/reject/link-decision actions, where a conflict means "someone else
 * already handled this" (spec section 10); everywhere else the server's own message is shown.
 */
function finish<T>(res: FunctionResult<T>, ok: (data: T) => ActionResult, registration = false): ActionResult {
  // Refresh in both outcomes: a conflict means the list on screen was stale.
  revalidatePath("/admin", "layout");
  revalidatePath("/owner", "layout");
  if ("error" in res) {
    if (registration && res.error.code === "conflict") return fail("conflict");
    return fail(res.error.code, res.error.message || messageFor(res.error.code));
  }
  return ok(res.data);
}

const isId = (v: unknown): v is string =>
  typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);

/** Everything the admin must follow up after an approval, in one line each (undefined when all went well). */
function approvalWarnings(d: {
  emailsSent: boolean;
  parentLinked: boolean;
  parentInvited: boolean;
  warning?: string;
}): string | undefined {
  const lines: string[] = [];
  if (d.warning) lines.push(WARNING_TEXT[d.warning] ?? d.warning);
  if (!d.emailsSent) lines.push("Approval email not sent");
  // A specific warning (parent email in use, parent suspended, ...) already explains a missing invite.
  if (!d.parentLinked && !d.parentInvited && !d.warning) lines.push("Parent not invited — use Resend parent invite");
  return lines.length ? lines.join(". ") : undefined;
}

export async function approveAction(studentId: string): Promise<ActionResult> {
  const a = await authorised();
  if ("denied" in a) return a.denied;
  if (!isId(studentId)) return fail("invalid_input");
  return finish(await approveStudent(a.client, studentId), (d) => ({
    ok: true,
    message: `Approved. Index number ${d.indexNumber}`,
    warning: approvalWarnings(d),
  }), true);
}

export async function rejectAction(studentId: string): Promise<ActionResult> {
  const a = await authorised();
  if ("denied" in a) return a.denied;
  if (!isId(studentId)) return fail("invalid_input");
  return finish(await rejectStudent(a.client, studentId), () => ({ ok: true, message: "Registration rejected and deleted." }), true);
}

export async function linkRequestAction(requestId: string, decision: "approve" | "reject"): Promise<ActionResult> {
  const a = await authorised();
  if ("denied" in a) return a.denied;
  if (!isId(requestId) || (decision !== "approve" && decision !== "reject")) return fail("invalid_input");
  const res = await parentChild(a.client, { action: decision === "approve" ? "approve_link" : "reject_link", requestId });
  return finish(res, () => ({ ok: true, message: decision === "approve" ? "Parent linked to child." : "Link request rejected." }), true);
}

/** Maps the parent-invite rebuild outcome. Linking an existing parent is a success even when no email was needed. */
function resendParentOutcome(r: {
  emailSent?: boolean;
  parentLinked?: boolean;
  parentInvited?: boolean;
  warning?: string;
}): ActionResult {
  const warning = r.warning ? (WARNING_TEXT[r.warning] ?? r.warning) : undefined;
  if (!r.parentLinked && !r.parentInvited) {
    return { ok: false, code: "conflict", message: warning ?? "The parent could not be linked." };
  }
  if (r.parentInvited && !r.parentLinked) {
    return { ok: false, code: "conflict", message: `Parent invited; not linked: ${warning ?? "the link was not created."}` };
  }
  if (r.parentInvited) {
    return r.emailSent
      ? { ok: true, message: "Parent invited and linked. The invitation email was sent.", warning }
      : {
          ok: true,
          message: "Parent account created and linked, but the invitation email could not be sent.",
          warning: warning ?? "Use Resend invite on the parent account.",
        };
  }
  return { ok: true, message: "Parent linked to the student.", warning };
}

export async function accountAction(
  kind: "suspend" | "reactivate" | "resend_invite" | "remove_staff" | "delete_account",
  userId: string,
): Promise<ActionResult> {
  const a = await authorised();
  if ("denied" in a) return a.denied;
  if (!isId(userId)) return fail("invalid_input");
  if (!["suspend", "reactivate", "resend_invite", "remove_staff", "delete_account"].includes(kind)) return fail("invalid_input");
  const res = await accountAdmin(a.client, { action: kind, userId });
  return finish(res, (d) => {
    switch (kind) {
      case "suspend":
        return { ok: true, message: "Account suspended." };
      case "reactivate":
        return { ok: true, message: "Account reactivated." };
      case "remove_staff":
        return { ok: true, message: "Staff account removed." };
      case "delete_account":
        return { ok: true, message: "Account deleted." };
      default: {
        const r = d as { emailSent?: boolean; parentLinked?: boolean; parentInvited?: boolean; warning?: string };
        if ("parentLinked" in r) return resendParentOutcome(r);
        return r.emailSent === false
          ? { ok: false, code: "internal", message: "The invitation email could not be sent. Try again later." }
          : { ok: true, message: "Invitation sent." };
      }
    }
  });
}

export async function inviteAction(input: {
  email: string;
  firstName: string;
  lastName: string;
  role: AppRole;
}): Promise<ActionResult> {
  const a = await authorised();
  if ("denied" in a) return a.denied;
  const email = String(input?.email ?? "").trim();
  const firstName = String(input?.firstName ?? "").trim();
  const lastName = String(input?.lastName ?? "").trim();
  if (!email.includes("@") || !firstName || !lastName) return fail("invalid_input");
  return finish(await inviteUser(a.client, { email, firstName, lastName, role: input.role }), (d) =>
    d.emailSent
      ? { ok: true, message: `Invitation sent to ${email}.` }
      : { ok: true, message: `Invitation created for ${email}, but the email could not be sent. Use Resend invite.` },
  );
}

export async function clearStuckInviteAction(email: string): Promise<ActionResult> {
  const a = await authorised();
  if ("denied" in a) return a.denied;
  const clean = String(email ?? "").trim();
  if (!clean.includes("@")) return fail("invalid_input");
  return finish(await accountAdmin(a.client, { action: "clear_stuck_invite", email: clean }), () => ({
    ok: true,
    message: "Stuck invite cleared.",
  }));
}

export async function editParentEmailAction(userId: string, parentEmail: string): Promise<ActionResult> {
  const a = await authorised();
  if ("denied" in a) return a.denied;
  const email = String(parentEmail ?? "").trim();
  if (!isId(userId) || !email.includes("@")) return fail("invalid_input");
  return finish(await accountAdmin(a.client, { action: "edit_parent_email", userId, parentEmail: email }), () => ({
    ok: true,
    message: "Parent email updated.",
  }));
}
