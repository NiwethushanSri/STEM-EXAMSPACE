import type { ErrorCode } from "../../../supabase/functions/_shared/errors.ts";

export type { ErrorCode };

/** Shown when GoTrue rejects a sign-in with its "banned" error (suspended staff). */
export const bannedMessage = "Your account is suspended, contact the institution";

const messages: Record<ErrorCode, string> = {
  email_in_use: "An account with this email already exists. Sign in or reset your password.",
  conflict: "This registration was already handled",
  invalid_credentials: "Index number or password is incorrect.",
  rate_limited: "Too many attempts. Try again later.",
  parent_email_is_staff: "The parent email belongs to a staff account. Edit the parent email first.",
  forbidden: "You do not have permission to do that.",
  not_found: "Not found.",
  unauthenticated: "Please sign in again.",
  invalid_input: "Please check the details you entered.",
  internal: "Something went wrong. Please try again.",
};

/** Fallback copy; a server-provided message takes precedence when present. */
export function messageFor(code: ErrorCode): string {
  return messages[code] ?? messages.internal;
}

/** Failure codes returned by the booking RPCs (create_booking, request_cancellation). */
const bookingMessages: Record<string, string> = {
  fully_booked: "This exam is fully booked",
  deadline_passed: "The booking deadline for this exam has passed.",
  not_bookable: "This exam cannot be booked.",
  already_booked: "This student already has a booking for this exam.",
  too_many_unpaid: "You have 3 unpaid bookings. Pay or cancel one before booking another.",
  forbidden: "You do not have permission to do that.",
  invalid_input: "This student cannot be booked. Check that their account is active.",
  conflict: "This booking can no longer be changed. Refresh the page and check its status.",
  not_found: "Not found.",
};

/** Message for a booking RPC failure code; unknown codes get the generic message. */
export function bookingMessageFor(code: string | null | undefined): string {
  return code && Object.hasOwn(bookingMessages, code) ? bookingMessages[code] : messages.internal;
}

/** Which exam or venue RPC a failure code came from; the same code reads differently for each. */
export type ExamContext = "save_exam" | "save_venue" | "set_status";

const examMessages: Record<ExamContext, Record<string, string>> = {
  save_exam: {
    forbidden: "You do not have permission to change this exam. Teachers can only edit draft exams in their own subjects.",
    invalid_input:
      "Check the exam details: the title, start time, duration (15 to 600 minutes), seat limit (1 to 1000), price (up to £1,000) and a booking deadline no later than the start. A published exam cannot be moved into the past, and an in-person exam needs an active venue and one of its rooms.",
    conflict:
      "This exam cannot be changed that way. It may be cancelled or completed, or its subject or price may be locked because it already has bookings.",
    not_found: "This exam no longer exists. Refresh the page.",
  },
  save_venue: {
    forbidden: "You do not have permission to change venues.",
    invalid_input:
      "Check the venue: a name of up to 80 characters, and up to 50 rooms of up to 40 characters each, with no repeats.",
    conflict:
      "A venue with that name already exists, or an upcoming exam still uses this venue or a room you removed. Move or cancel those exams first.",
    not_found: "This venue no longer exists. Refresh the page.",
  },
  set_status: {
    forbidden: "You do not have permission to change an exam's status.",
    invalid_input:
      "This exam cannot be published yet: its start time and booking deadline must be in the future, and an in-person exam needs an active venue and one of its rooms.",
    conflict: "This exam's status has already changed. Refresh the page to see where it stands.",
    not_found: "This exam no longer exists. Refresh the page.",
  },
};

/** Message for an exam or venue RPC failure code; unknown codes get the generic message. */
export function examMessageFor(code: string | null | undefined, context: ExamContext): string {
  const table = examMessages[context];
  return code && Object.hasOwn(table, code) ? table[code] : messages.internal;
}

/** Which admin booking or finance RPC a failure code came from; the same code reads differently for each. */
export type AdminBookingContext = "add" | "mark_paid" | "cancel" | "approve" | "decline" | "finance";

const FORBIDDEN = "You do not have permission to do that.";
const REFRESH = "This booking has already changed. Refresh the page to see where it stands.";

const adminBookingMessages: Record<AdminBookingContext, Record<string, string>> = {
  add: {
    forbidden: FORBIDDEN,
    invalid_input: "Check the student: they must be an active student account. A note can be up to 500 characters.",
    not_found: "This exam no longer exists. Refresh the page.",
    not_bookable: "This exam cannot be booked: it must be published, have a confirmed price and not have started.",
    deadline_passed: "The booking deadline has passed, so an unpaid booking cannot be added. Add it as paid instead.",
    already_booked: "This student already has a booking for this exam.",
    fully_booked: "This exam is fully booked",
  },
  mark_paid: {
    forbidden: FORBIDDEN,
    invalid_input: "A note can be up to 500 characters.",
    not_found: "This booking no longer exists. Refresh the page.",
    conflict: REFRESH,
  },
  cancel: {
    forbidden: FORBIDDEN,
    invalid_input: "A note can be up to 500 characters.",
    not_found: "This booking no longer exists. Refresh the page.",
    conflict: REFRESH,
  },
  approve: {
    forbidden: FORBIDDEN,
    invalid_input: "Enter a refund between £0 and the amount still refundable. A note can be up to 500 characters.",
    not_found: "This booking no longer exists. Refresh the page.",
    conflict: REFRESH,
  },
  decline: {
    forbidden: FORBIDDEN,
    invalid_input: "A note can be up to 500 characters.",
    not_found: "This booking no longer exists. Refresh the page.",
    conflict:
      "This request cannot be declined: it may already be decided, or the exam was cancelled so the family is owed a refund. Refresh the page.",
  },
  finance: {
    forbidden: FORBIDDEN,
    invalid_input: "Choose a valid date range: both dates are required and the start cannot be after the end.",
  },
};

/** Message for an admin booking or finance RPC failure code; unknown codes get the generic message. */
export function adminBookingMessageFor(code: string | null | undefined, context: AdminBookingContext): string {
  const table = adminBookingMessages[context];
  return code && Object.hasOwn(table, code) ? table[code] : messages.internal;
}
