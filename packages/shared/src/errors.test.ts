import { describe, expect, it } from "vitest";
import { bannedMessage, messageFor, type ErrorCode } from "./errors";

const table: Record<ErrorCode, string> = {
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

describe("messageFor", () => {
  it.each(Object.entries(table))("%s", (code, msg) => {
    expect(messageFor(code as ErrorCode)).toBe(msg);
  });
  it("bannedMessage", () => {
    expect(bannedMessage).toBe("Your account is suspended, contact the institution");
  });
});
