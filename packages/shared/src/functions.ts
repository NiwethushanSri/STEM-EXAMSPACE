import type { ErrorCode } from "./errors";
import { messageFor } from "./errors";
import type { AccountStatus, AppRole } from "./roles";
import type { StemClient } from "./supabase";

export type FunctionName =
  | "approve-student"
  | "reject-student"
  | "index-login"
  | "invite-user"
  | "account-admin"
  | "delete-my-account"
  | "parent-child"
  | "register-student"
  | "paper-register"
  | "paper-copy";

export type FunctionError = { code: ErrorCode; message: string };
export type FunctionResult<T> = { data: T } | { error: FunctionError };

const CODES = [
  "unauthenticated", "forbidden", "not_found", "conflict", "invalid_input",
  "parent_email_is_staff", "email_in_use", "rate_limited", "invalid_credentials", "internal",
  "paper_missing", "paper_held", "roles_not_reviewed", "paper_not_released", "paper_closed", "wrong_sitting",
  "paper_unreadable", "paper_encrypted", "paper_too_large",
] as const satisfies readonly ErrorCode[];

// Compile-time check: every ErrorCode must appear in CODES (resolves to never otherwise).
type MissingCodes = Exclude<ErrorCode, (typeof CODES)[number]>;
const _allCodesListed: [MissingCodes] extends [never] ? true : never = true;
void _allCodesListed;

function internal(): { error: FunctionError } {
  return { error: { code: "internal", message: messageFor("internal") } };
}

function fromStatus(status: unknown): { error: FunctionError } {
  const code: ErrorCode =
    status === 401 ? "unauthenticated" : status === 403 ? "forbidden" : status === 429 ? "rate_limited" : "internal";
  return { error: { code, message: messageFor(code) } };
}

/**
 * Invokes an Edge Function with the client's session. Never throws: HTTP errors are parsed from the
 * `{ error: { code, message } }` body; gateway failures without a code map by HTTP status
 * (401/403/429); network or unparseable failures become `internal`.
 */
export async function callFunction<T>(
  client: StemClient,
  name: FunctionName,
  body: object,
): Promise<FunctionResult<T>> {
  try {
    const { data, error } = await client.functions.invoke(name, { body });
    if (!error) return { data: data as T };
    // Duck-typed: React Native fetch polyfills may use a different Response class.
    const ctx = (error as { context?: { json?: unknown; status?: unknown } | null }).context;
    if (ctx && typeof ctx.json === "function") {
      try {
        const parsed = (await (ctx as { json: () => Promise<unknown> }).json()) as {
          error?: { code?: unknown; message?: unknown };
        } | null;
        const code = parsed?.error?.code;
        if (typeof code === "string" && (CODES as readonly string[]).includes(code)) {
          const message = parsed?.error?.message;
          return {
            error: {
              code: code as ErrorCode,
              message: typeof message === "string" && message ? message : messageFor(code as ErrorCode),
            },
          };
        }
      } catch {
        // body unreadable: fall back to the status below
      }
      return fromStatus(ctx.status);
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
/** Always the same answer: a new, replaced or already registered address cannot be told apart. */
export type RegisterStudentResult = { ok: true };

export type RegisterStudentInput = {
  firstName: string;
  lastName: string;
  email: string;
  /** YYYY-MM-DD; the student must be 8 to 25 years old. */
  dateOfBirth: string;
  school: string;
  parentName: string;
  parentEmail: string;
  /** Optional on the server so older clients keep working; the web form asks for it. */
  parentPhone?: string;
};

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
  | { action: "clear_stuck_invite"; email: string }
  | { action: "edit_parent_email"; userId: string; parentEmail: string };

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
    ? { status: AccountStatus }
    : A extends "remove_staff"
      ? { removed: true }
      : A extends "delete_account"
        ? { deleted: true }
        : A extends "edit_parent_email"
          ? { updated: true }
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

/** Public student sign-up. Needs no session and takes no password: the emailed link confirms the address and lets the student choose one. Always answers { ok: true }. */
export const registerStudent = (client: StemClient, input: RegisterStudentInput) =>
  callFunction<RegisterStudentResult>(client, "register-student", input);

export type RegisterExamPaperInput = {
  examId: string;
  kind: "paper" | "insert";
  title?: string;
  storagePath: string;
  reason?: string;
};
export type RegisterExamPaperResult = { paperId: string; version: number; pageCount: number };

/** Owner/admin: checks the uploaded PDF and registers it as the exam's paper (or an insert). */
export const registerExamPaper = (client: StemClient, input: RegisterExamPaperInput) =>
  callFunction<RegisterExamPaperResult>(client, "paper-register", input);

export type PaperCopyInput =
  | { bookingId: string; kind: "home" | "print_pack" | "reprint" | "admin_preview" }
  | { bookingId: string; insertId: string }
  /** Owner/admin: a sample candidate's copy of one paper version (no booking, nothing logged). */
  | { paperId: string; kind: "admin_sample" };

function parseFunctionError(parsed: unknown): FunctionError | null {
  const e = (parsed as { error?: { code?: unknown; message?: unknown } } | null)?.error;
  const code = e?.code;
  if (typeof code !== "string" || !(CODES as readonly string[]).includes(code)) return null;
  return {
    code: code as ErrorCode,
    message: typeof e?.message === "string" && e.message ? e.message : messageFor(code as ErrorCode),
  };
}

/** Where the Edge Functions are: the project URL and its public anon key (the same two the client was made with). */
export type FunctionsEndpoint = { url: string; anonKey: string };

/**
 * Downloads a candidate's personalised paper (or an insert unchanged). Uses fetch with the session token because
 * `functions.invoke` parses JSON; the client only supplies the session. `version` is the paper version the copy
 * was made from (null for an insert). Never throws.
 */
export async function downloadPaperCopy(
  client: StemClient,
  input: PaperCopyInput,
  endpoint: FunctionsEndpoint,
): Promise<{ data: { blob: Blob; fileName: string; differs: boolean; version: number | null } } | { error: FunctionError }> {
  try {
    if (!endpoint?.url || !endpoint.anonKey) return internal();
    const { data: sess } = await client.auth.getSession();
    const token = sess.session?.access_token;
    if (!token) return fromStatus(401);
    const res = await fetch(`${endpoint.url.replace(/\/+$/, "")}/functions/v1/paper-copy`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, apikey: endpoint.anonKey, "Content-Type": "application/json" },
      body: JSON.stringify(input),
    });
    if (!res.ok) {
      let parsed: FunctionError | null = null;
      try {
        parsed = parseFunctionError(await res.json());
      } catch {
        // body unreadable: fall back to the status below
      }
      return parsed ? { error: parsed } : fromStatus(res.status);
    }
    const named = /filename="([^"]+)"/.exec(res.headers.get("Content-Disposition") ?? "");
    const v = Number(res.headers.get("X-Paper-Version") ?? "");
    return {
      data: {
        blob: await res.blob(),
        fileName: named?.[1] ?? "paper.pdf",
        differs: res.headers.get("X-Paper-Differs") === "1",
        version: Number.isInteger(v) && v > 0 ? v : null,
      },
    };
  } catch {
    return internal();
  }
}
