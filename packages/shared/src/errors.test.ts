import { describe, expect, it } from "vitest";
import { adminBookingMessageFor, attendanceMessageFor, bannedMessage, collectionMessageFor, bookingMessageFor, examMessageFor, exceptionMessageFor, messageFor, scanMessageFor, scriptMessageFor, uploadMessageFor, type ErrorCode } from "./errors";

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
  paper_missing: "Your paper is not ready yet. The institution has been told.",
  paper_held: "The paper is paused by the institution. Please wait.",
  paper_not_released: "Your paper is not ready to download yet.",
  paper_closed: "Downloads for this paper have closed.",
  wrong_sitting: "Your booking is for the centre; your paper is handed out in the exam room",
  paper_unreadable: "The paper could not be prepared. Please try again.",
  paper_encrypted: "This PDF is password protected. Remove the password and upload it again.",
  paper_too_large: "This PDF is larger than 20 MB. Make it smaller and upload it again.",
};

describe("messageFor", () => {
  it.each(Object.entries(table))("%s", (code, msg) => {
    expect(messageFor(code as ErrorCode)).toBe(msg);
  });
  it("bannedMessage", () => {
    expect(bannedMessage).toBe("Your account is suspended, contact the institution");
  });
});

describe("bookingMessageFor", () => {
  it("maps booking codes", () => {
    expect(bookingMessageFor("centre_full")).toBe("That centre is full. Choose another centre if there is one.");
    for (const code of ["choose_sitting", "choose_centre", "sitting_not_offered"]) {
      expect(bookingMessageFor(code)).not.toBe("Something went wrong. Please try again.");
    }
    expect(bookingMessageFor("too_many_unpaid")).toBe("You have 3 unpaid bookings. Pay or cancel one before booking another.");
  });
  it("maps change_sitting codes", () => {
    expect(adminBookingMessageFor("centre_full", "change_sitting")).toBe("That centre is full. Choose another centre if there is one.");
    expect(adminBookingMessageFor("choose_centre", "change_sitting")).toContain("centre");
  });
  it("falls back to the generic message", () => {
    expect(bookingMessageFor("nope")).toBe("Something went wrong. Please try again.");
    expect(bookingMessageFor(undefined)).toBe("Something went wrong. Please try again.");
  });
});

describe("bookingMessageFor (prototype keys)", () => {
  it.each(["constructor", "toString", "__proto__", "hasOwnProperty"])("%s is not a code", (code) => {
    expect(bookingMessageFor(code)).toBe("Something went wrong. Please try again.");
  });
});

describe("examMessageFor", () => {
  it("maps each code per context", () => {
    expect(examMessageFor("conflict", "save_venue")).toContain("upcoming exam still uses this venue");
    expect(examMessageFor("conflict", "set_status")).toContain("status has already changed");
    expect(examMessageFor("invalid_input", "save_exam")).toContain("1 to 1000 seats");
    expect(examMessageFor("not_found", "set_status")).toBe("This exam no longer exists. Refresh the page.");
  });
  it("falls back to the generic message", () => {
    expect(examMessageFor("nope", "save_exam")).toBe("Something went wrong. Please try again.");
    expect(examMessageFor(undefined, "set_status")).toBe("Something went wrong. Please try again.");
  });
  it.each(["constructor", "toString", "__proto__", "hasOwnProperty"])("%s is not a code", (code) => {
    expect(examMessageFor(code, "save_exam")).toBe("Something went wrong. Please try again.");
  });
});

describe("adminBookingMessageFor", () => {
  it("maps each code per context", () => {
    expect(adminBookingMessageFor("deadline_passed", "add")).toContain("Add it as paid instead");
    expect(adminBookingMessageFor("conflict", "mark_paid")).toContain("already changed");
    expect(adminBookingMessageFor("conflict", "decline")).toContain("exam was cancelled");
    expect(adminBookingMessageFor("invalid_input", "approve")).toContain("amount still refundable");
    expect(adminBookingMessageFor("invalid_input", "finance")).toContain("date range");
    expect(adminBookingMessageFor("forbidden", "cancel")).toBe("You do not have permission to do that.");
  });
  it("falls back to the generic message", () => {
    expect(adminBookingMessageFor("nope", "add")).toBe("Something went wrong. Please try again.");
    expect(adminBookingMessageFor(undefined, "finance")).toBe("Something went wrong. Please try again.");
    expect(adminBookingMessageFor("centre_full", "finance")).toBe("Something went wrong. Please try again.");
  });
  it.each(["constructor", "toString", "__proto__", "hasOwnProperty"])("%s is not a code", (code) => {
    expect(adminBookingMessageFor(code, "add")).toBe("Something went wrong. Please try again.");
  });
});

describe("attendanceMessageFor", () => {
  it("maps each code per context", () => {
    expect(attendanceMessageFor("not_found", "lookup")).toBe("Not found");
    expect(attendanceMessageFor("not_booked", "mark")).toBe("No paid booking");
    expect(attendanceMessageFor("conflict", "mark")).toContain("register is closed");
    expect(attendanceMessageFor("conflict", "close")).toContain("already started");
  });
  it("falls back to the generic message", () => {
    expect(attendanceMessageFor("nope", "lookup")).toBe("Something went wrong. Please try again.");
    expect(attendanceMessageFor(undefined, "close")).toBe("Something went wrong. Please try again.");
    expect(attendanceMessageFor("not_booked", "close")).toBe("Something went wrong. Please try again.");
  });
  it.each(["constructor", "toString", "__proto__", "hasOwnProperty"])("%s is not a code", (code) => {
    expect(attendanceMessageFor(code, "mark")).toBe("Something went wrong. Please try again.");
  });
});

describe("uploadMessageFor", () => {
  it("maps the home upload codes", () => {
    expect(uploadMessageFor("uploads_not_open")).toBe("You can upload your answers once the exam has started.");
    expect(uploadMessageFor("uploads_closed")).toBe("Uploads for this exam have closed. Please contact the institution.");
    expect(uploadMessageFor("too_many_files")).toContain("at most 60 files");
    expect(uploadMessageFor("file_too_large")).toContain("25 MB");
    expect(uploadMessageFor("file_too_large")).toContain("100 MB");
    expect(uploadMessageFor("wrong_file_type")).toContain("PDF");
    expect(uploadMessageFor("still_uploading")).toContain("still uploading");
    expect(uploadMessageFor("nothing_to_submit")).toContain("at least one");
    expect(uploadMessageFor("wrong_sitting")).toContain("centre");
    expect(uploadMessageFor("conflict")).toContain("Refresh");
  });
  it("falls back to the generic message", () => {
    expect(uploadMessageFor("nope")).toBe("Something went wrong. Please try again.");
    expect(uploadMessageFor(undefined)).toBe("Something went wrong. Please try again.");
  });
  it.each(["constructor", "toString", "__proto__", "hasOwnProperty"])("%s is not a code", (code) => {
    expect(uploadMessageFor(code)).toBe("Something went wrong. Please try again.");
  });
});

describe("collectionMessageFor", () => {
  it("maps each code per context", () => {
    expect(collectionMessageFor("not_present", "record")).toContain("present or late");
    expect(collectionMessageFor("invalid_staff", "custody")).toContain("active account");
    expect(collectionMessageFor("conflict", "manifest")).toContain("99");
  });
  it("says a removed centre takes nothing more", () => {
    expect(collectionMessageFor("conflict", "manifest")).toContain("no longer part of this exam");
    expect(collectionMessageFor("conflict", "record")).toContain("no longer part of this exam");
    expect(collectionMessageFor("conflict", "custody")).toContain("no longer part of this exam");
  });
  it("falls back to the generic message", () => {
    expect(collectionMessageFor("nope", "record")).toBe("Something went wrong. Please try again.");
    expect(collectionMessageFor("not_present", "custody")).toBe("Something went wrong. Please try again.");
    expect(collectionMessageFor("__proto__", "custody")).toBe("Something went wrong. Please try again.");
  });
});

describe("scanMessageFor", () => {
  it("maps each code per context", () => {
    expect(scanMessageFor("unknown_manifest", "create")).toContain("No manifest has that number");
    expect(scanMessageFor("other_manifest", "create")).toContain("another centre or exam");
    expect(scanMessageFor("conflict", "create")).toContain("no longer part of this exam");
    expect(scanMessageFor("wrong_file_type", "upload")).toContain("PDF, JPEG or PNG");
    expect(scanMessageFor("file_too_large", "upload")).toContain("1 GB");
    expect(scanMessageFor("conflict", "upload")).toContain("new scan batch");
    expect(scanMessageFor("not_found", "upload")).toContain("did not arrive");
    expect(scanMessageFor("nothing_to_submit", "submit")).toContain("at least one file");
    expect(scanMessageFor("still_processing", "complete")).toContain("still uploading or being processed");
    expect(scanMessageFor("forbidden", "complete")).toBe("You do not have permission to do that.");
  });
  it("falls back to the generic message", () => {
    expect(scanMessageFor("nope", "create")).toBe("Something went wrong. Please try again.");
    expect(scanMessageFor("still_processing", "create")).toBe("Something went wrong. Please try again.");
    expect(scanMessageFor("__proto__", "upload")).toBe("Something went wrong. Please try again.");
    expect(scanMessageFor(undefined, "submit")).toBe("Something went wrong. Please try again.");
  });
});

describe("exceptionMessageFor", () => {
  it("maps each code of the exception queue", () => {
    expect(exceptionMessageFor("reason_required")).toBe("Give a reason of 3 to 300 characters.");
    expect(exceptionMessageFor("other_exam")).toContain("another exam");
    expect(exceptionMessageFor("not_present")).toContain("present or late");
    expect(exceptionMessageFor("wrong_sitting")).toContain("at home");
    expect(exceptionMessageFor("booking_not_active")).toContain("not paid");
    expect(exceptionMessageFor("in_other_script")).toContain("another candidate");
    expect(exceptionMessageFor("script_locked")).toContain("marked");
    expect(exceptionMessageFor("page_replaced")).toContain("processed again");
    expect(exceptionMessageFor("still_mixed")).toContain("two versions");
    expect(exceptionMessageFor("not_late")).toContain("late");
    expect(exceptionMessageFor("name_not_hidden")).toContain("There is no name on this page");
    expect(exceptionMessageFor("other_family")).toContain("another family");
    expect(exceptionMessageFor("wrong_kind")).toContain("does not fit");
    expect(exceptionMessageFor("invalid_input")).toContain("copy");
    expect(exceptionMessageFor("conflict")).toContain("already been resolved");
    expect(exceptionMessageFor("forbidden")).toBe("You do not have permission to do that.");
  });
  it("falls back to the generic message", () => {
    expect(exceptionMessageFor("nope")).toBe("Something went wrong. Please try again.");
    expect(exceptionMessageFor("__proto__")).toBe("Something went wrong. Please try again.");
    expect(exceptionMessageFor(undefined)).toBe("Something went wrong. Please try again.");
  });
});

describe("scriptMessageFor", () => {
  it("maps each code of the script repository", () => {
    expect(scriptMessageFor("reason_required")).toBe("Give a reason of 3 to 300 characters.");
    expect(scriptMessageFor("script_locked")).toContain("being marked");
    expect(scriptMessageFor("page_replaced")).toContain("processed again");
    expect(scriptMessageFor("not_found")).toContain("Refresh");
    expect(scriptMessageFor("invalid_input")).toContain("Check");
    expect(scriptMessageFor("forbidden")).toBe("You do not have permission to do that.");
  });
  it("says why a conflict was refused", () => {
    expect(scriptMessageFor("conflict", "busy")).toContain("already waiting");
    expect(scriptMessageFor("conflict", "void")).toContain("already void");
    expect(scriptMessageFor("conflict", "changed")).toContain("changed");
    expect(scriptMessageFor("conflict")).toContain("changed");
  });
  it("falls back to the generic message", () => {
    expect(scriptMessageFor("nope")).toBe("Something went wrong. Please try again.");
    expect(scriptMessageFor("__proto__")).toBe("Something went wrong. Please try again.");
    expect(scriptMessageFor(undefined)).toBe("Something went wrong. Please try again.");
  });
});
