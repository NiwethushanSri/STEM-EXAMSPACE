import type { ErrorCode } from "./errors";
import { messageFor } from "./errors";
import type { AppRole } from "./roles";
import type { StemClient } from "./supabase";

export type FunctionName =
  | "approve-student"
  | "reject-student"
  | "index-login"
  | "invite-user"
  | "account-admin"
  | "delete-my-account"
  | "parent-child";

export type FunctionError = { code: ErrorCode; message: string };
export type FunctionResult<T> = { data: T } | { error: FunctionError };

const CODES: readonly string[] = [
  "unauthenticated", "forbidden", "not_found", "conflict", "invalid_input",
  "parent_email_is_staff", "email_in_use", "rate_limited", "invalid_credentials", "internal",
];

function internal(): { error: FunctionError } {
  return { error: { code: "internal", message: messageFor("internal") } };
}

/**
 * Invokes an Edge Function with the client's session. Never throws: HTTP errors are parsed from the
 * `{ error: { code, message } }` body; network or unparseable failures become `internal`.
 */
export async function callFunction<T>(
  client: StemClient,
  name: FunctionName,
  body: object,
): Promise<FunctionResult<T>> {
  try {
    const { data, error } = await client.functions.invoke(name, { body });
    if (!error) return { data: data as T };
    const ctx = (error as { context?: unknown }).context;
    if (ctx instanceof Response) {
      try {
        const parsed = (await ctx.json()) as { error?: { code?: unknown; message?: unknown } };
        const code = parsed?.error?.code;
        if (typeof code === "string" && CODES.includes(code)) {
          const message = parsed.error?.message;
          return {
            error: {
              code: code as ErrorCode,
              message: typeof message === "string" && message ? message : messageFor(code as ErrorCode),
            },
          };
        }
      } catch {
        // fall through to internal
      }
    }
    return internal();
  } catch {
    return internal();
  }
}

// ---- Response shapes (match supabase/functions/*/index.ts) ----

export type ApproveStudentResult = {
  indexNumber: string;
  parentInvited: boolean;
  parentLinked: boolean;
  emailsSent: boolean;
  warning?: string;
};
export type RejectStudentResult = { emailSent: boolean };
export type IndexLoginResult = { access_token: string; refresh_token: string; expires_in: number };
export type InviteUserResult = { invited: true; emailSent: boolean };
export type DeleteMyAccountResult = { deleted: true };

export type InviteUserInput = {
  email: string;
  firstName: string;
  lastName: string;
  /** Owner may invite admin/teacher/tutor/corrector; admin may invite teacher/tutor/corrector. */
  role: AppRole;
};

export type AccountAdminAction =
  | { action: "resend_invite"; userId: string }
  | { action: "suspend"; userId: string }
  | { action: "reactivate"; userId: string }
  | { action: "remove_staff"; userId: string }
  | { action: "delete_account"; userId: string }
  | { action: "clear_stuck_invite"; email: string };

export type ParentLinkOutcome = {
  parentLinked: boolean;
  parentInvited: boolean;
  emailSent: boolean;
  warning?: "parent_suspended" | "link_blocked";
};
/** resend_invite answers { emailSent } for staff/parent accounts, or ParentLinkOutcome when rebuilding a student's parent invite. */
export type AccountAdminResult<A extends AccountAdminAction["action"]> = A extends "resend_invite"
  ? { emailSent: boolean } | ParentLinkOutcome
  : A extends "suspend" | "reactivate"
    ? { status: string }
    : A extends "remove_staff"
      ? { removed: true }
      : A extends "delete_account"
        ? { deleted: true }
        : { cleared: true };

export type ParentChildAction =
  | {
      action: "register";
      child: { firstName: string; lastName: string; school: string; email: string; dateOfBirth: string };
    }
  | { action: "link"; indexNumber: string; dateOfBirth: string }
  | { action: "approve_link"; requestId: string }
  | { action: "reject_link"; requestId: string };

export type ParentChildResult<A extends ParentChildAction["action"]> = A extends "register"
  ? { registered: true; emailSent: boolean }
  : A extends "link"
    ? { requested: true }
    : A extends "approve_link"
      ? { approved: true }
      : { rejected: true };

// ---- Typed helpers ----

export const approveStudent = (client: StemClient, studentId: string) =>
  callFunction<ApproveStudentResult>(client, "approve-student", { studentId });

export const rejectStudent = (client: StemClient, studentId: string) =>
  callFunction<RejectStudentResult>(client, "reject-student", { studentId });

export const indexLogin = (client: StemClient, indexNumber: string, password: string) =>
  callFunction<IndexLoginResult>(client, "index-login", { indexNumber, password });

export const inviteUser = (client: StemClient, input: InviteUserInput) =>
  callFunction<InviteUserResult>(client, "invite-user", input);

export const accountAdmin = <A extends AccountAdminAction>(client: StemClient, action: A) =>
  callFunction<AccountAdminResult<A["action"]>>(client, "account-admin", action);

export const deleteMyAccount = (client: StemClient) =>
  callFunction<DeleteMyAccountResult>(client, "delete-my-account", {});

export const parentChild = <A extends ParentChildAction>(client: StemClient, action: A) =>
  callFunction<ParentChildResult<A["action"]>>(client, "parent-child", action);
