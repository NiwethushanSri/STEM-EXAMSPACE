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
