import { describe, expect, it } from "vitest";
import { ACCEPT_REASON_MESSAGE, acceptDraftMessage, acceptReasonProblem, draftCandidate, familyNoticesLine, parseUnsentDrafts, replacesNote, skipNoticesMessage } from "@/lib/home-drafts";

const SUB = "11111111-1111-4111-8111-111111111111";
const BOOKING = "22222222-2222-4222-8222-222222222222";
const EXAM = "33333333-3333-4333-8333-333333333333";

const item = {
  submission_id: SUB,
  booking: { id: BOOKING, sitting: "home", status: "paid", centre_id: null, name: "Sam One", index_number: "SE-2098-7701" },
  exam: { id: EXAM, title: "Maths mock", paper: "Paper 1", starts_at: "2031-06-07T09:00:00Z" },
  files: 3,
  last_file_at: "2031-06-07T11:20:00Z",
  late: true,
};

describe("parseUnsentDrafts", () => {
  it("reads the list of drafts with stored files", () => {
    expect(parseUnsentDrafts({ ok: true, now: "2031-06-08T12:00:00Z", items: [item] })).toEqual([
      {
        submissionId: SUB,
        bookingId: BOOKING,
        name: "Sam One",
        indexNumber: "SE-2098-7701",
        exam: { id: EXAM, title: "Maths mock", paper: "Paper 1", startsAt: "2031-06-07T09:00:00Z" },
        files: 3,
        lastFileAt: "2031-06-07T11:20:00Z",
        late: true,
        replacesReceived: false,
        replacesAll: true,
        receivedPages: 0,
      },
    ]);
  });
  it("is null for a refusal or a broken answer, and leaves out malformed rows", () => {
    expect(parseUnsentDrafts({ ok: false, code: "forbidden" })).toBeNull();
    expect(parseUnsentDrafts(null)).toBeNull();
    expect(parseUnsentDrafts({ ok: true })).toBeNull();
    expect(parseUnsentDrafts({ ok: true, items: [{ files: 2 }, { ...item, booking: null, exam: null, late: "yes" }] })).toEqual([
      {
        submissionId: SUB, bookingId: null, name: null, indexNumber: null, exam: null, files: 3, lastFileAt: "2031-06-07T11:20:00Z", late: false,
        replacesReceived: false, replacesAll: true, receivedPages: 0,
      },
    ]);
  });
  it("reads whether a draft replaces pages already received", () => {
    const [d] = parseUnsentDrafts({ ok: true, items: [{ ...item, replaces_received: true, replaces_all: true, received_pages: 3 }] })!;
    expect([d.replacesReceived, d.replacesAll, d.receivedPages]).toEqual([true, true, 3]);
    expect(replacesNote(d)).toBe("Submitting this replaces all 3 pages already received.");
    expect(replacesNote({ ...d, replacesAll: false })).toBe("Submitting this replaces some of the pages already received.");
    expect(replacesNote({ ...d, replacesReceived: false })).toBeNull();
  });
  it("names the candidate", () => {
    const [d] = parseUnsentDrafts({ ok: true, items: [item] })!;
    expect(draftCandidate(d)).toBe("Sam One (SE-2098-7701)");
    expect(draftCandidate({ ...d, indexNumber: null })).toBe("Sam One");
    expect(draftCandidate({ ...d, name: null, indexNumber: null })).toBe("A candidate");
  });
});

describe("accepting a draft for the family", () => {
  it("needs a reason of 3 to 300 characters", () => {
    expect(acceptReasonProblem("  ok ")).toBe(ACCEPT_REASON_MESSAGE);
    expect(acceptReasonProblem("Family phoned")).toBeNull();
    expect(acceptReasonProblem("x".repeat(301))).toBe(ACCEPT_REASON_MESSAGE);
  });
  it("says what happened", () => {
    expect(acceptDraftMessage({ ok: true, state: "checking", late: false, files: 2 } as never)).toEqual({
      ok: true,
      message: "2 files were submitted for the family and are being checked.",
    });
    expect(acceptDraftMessage({ ok: true, late: true, files: 1 }).message).toBe(
      "1 file was submitted for the family and is being checked. The hand-in is marked late: decide in the exception queue whether it is marked.",
    );
    expect(acceptDraftMessage({ ok: false, code: "conflict" })).toEqual({ ok: false, message: "These answers have already been submitted. Refresh the page." });
    expect(acceptDraftMessage({ ok: false, code: "forbidden" }).message).toBe("You do not have permission to do that.");
    expect(acceptDraftMessage({ ok: false, code: "script_locked" }).message).toContain("already being marked");
    expect(acceptDraftMessage({ ok: false, code: "something_new" }).message).toBe("Something went wrong. Please try again.");
  });
});

describe("family emails that are not sent", () => {
  it("says how many wait", () => {
    expect(familyNoticesLine(3)).toBe("3 family emails are waiting to be sent.");
    expect(familyNoticesLine(1)).toBe("1 family email is waiting to be sent.");
  });
  it("says what happened", () => {
    expect(skipNoticesMessage({ ok: true, skipped: 2 })).toEqual({ ok: true, message: "2 family emails were not sent." });
    expect(skipNoticesMessage({ ok: false, code: "reason_required" }).message).toBe(ACCEPT_REASON_MESSAGE);
    expect(skipNoticesMessage({ ok: false, code: "forbidden" }).message).toBe("You do not have permission to do that.");
    expect(skipNoticesMessage({ ok: false, code: "x" }).message).toBe("Something went wrong. Please try again.");
  });
});
