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

function finish<T>(res: FunctionResult<T>, ok: (data: T) => ActionResult): ActionResult {
  // Refresh in both outcomes: a conflict means the list on screen was stale.
  revalidatePath("/admin", "layout");
  revalidatePath("/owner", "layout");
  if ("error" in res) return fail(res.error.code, res.error.message || messageFor(res.error.code));
  return ok(res.data);
}

const isId = (v: unknown): v is string =>
  typeof v === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);

export async function approveAction(studentId: string): Promise<ActionResult> {
  const a = await authorised();
  if ("denied" in a) return a.denied;
  if (!isId(studentId)) return fail("invalid_input");
  return finish(await approveStudent(a.client, studentId), (d) => ({
    ok: true,
    message: `Approved. Index number ${d.indexNumber}`,
    warning: d.warning ? (WARNING_TEXT[d.warning] ?? d.warning) : undefined,
  }));
}

export async function rejectAction(studentId: string): Promise<ActionResult> {
  const a = await authorised();
  if ("denied" in a) return a.denied;
  if (!isId(studentId)) return fail("invalid_input");
  return finish(await rejectStudent(a.client, studentId), () => ({ ok: true, message: "Registration rejected and deleted." }));
}

export async function linkRequestAction(requestId: string, decision: "approve" | "reject"): Promise<ActionResult> {
  const a = await authorised();
  if ("denied" in a) return a.denied;
  if (!isId(requestId) || (decision !== "approve" && decision !== "reject")) return fail("invalid_input");
  const res = await parentChild(a.client, { action: decision === "approve" ? "approve_link" : "reject_link", requestId });
  return finish(res, () => ({ ok: true, message: decision === "approve" ? "Parent linked to child." : "Link request rejected." }));
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
        const r = d as { emailSent?: boolean; warning?: string };
        const warning = r.warning ? (WARNING_TEXT[r.warning] ?? r.warning) : undefined;
        return r.emailSent === false
          ? { ok: false, code: "internal", message: "The invitation email could not be sent. Try again later." }
          : { ok: true, message: "Invitation sent.", warning };
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
