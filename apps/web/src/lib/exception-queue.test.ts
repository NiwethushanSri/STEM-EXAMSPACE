import { describe, expect, it } from "vitest";
import {
  KIND_LABEL,
  actionLabel,
  actionsFor,
  conflictMessage,
  failureMessage,
  foundInWords,
  needsNameCheck,
  parseCandidates,
  parseQueue,
  reasonProblem,
  resolutionLabel,
  resolvedMessage,
  rpcFor,
  type QueueItem,
} from "./exception-queue";

const page = (over: Record<string, unknown> = {}) => ({
  id: "11111111-1111-4111-8111-111111111111",
  upload_id: "22222222-2222-4222-8222-222222222222",
  source_index: 6,
  copy_page: 2,
  state: "duplicate",
  blank: false,
  quality: { sharpness: 100, brightness: 180, cut_off: false, flags: [] },
  rotation: 0,
  full_path: "e/u/6-full.jpg",
  marking_path: "e/u/6-marking.jpg",
  placed_after: null,
  replaced: false,
  paper_version: 2,
  paper_current: true,
  areas: [{ x: 0.1, y: 0.05, w: 0.5, h: 0.04 }],
  ...over,
});

const raw = (over: Record<string, unknown> = {}) => ({
  id: "33333333-3333-4333-8333-333333333333",
  kind: "duplicate",
  state: "open",
  created_at: "2031-07-07T11:00:00Z",
  details: { copy_page: 2, kept_page_id: "44444444-4444-4444-8444-444444444444" },
  exam: { id: "55555555-5555-4555-8555-555555555555", title: "Maths", paper: "Paper 1", code: "MATH1" },
  booking: { id: "66666666-6666-4666-8666-666666666666", name: "Sam Pupil", index_number: "SE-2026-0001", sitting: "centre", status: "paid" },
  printed_for: { id: "66666666-6666-4666-8666-666666666666", name: "Sam Pupil", index_number: "SE-2026-0001", sitting: "centre", status: "paid" },
  script: { id: "77777777-7777-4777-8777-777777777777", number: "S-MATH1-0001", state: "needs_attention", source: "centre", version: 2, complete: false, late: false, late_decision: null },
  page: page(),
  kept_page: page({ id: "44444444-4444-4444-8444-444444444444", source_index: 5, state: "matched", paper_version: 1, paper_current: false, areas: [] }),
  linked_pages: null,
  upload: { id: "22222222-2222-4222-8222-222222222222", kind: "scan_file", state: "processed", source: "centre", position: 1, batch_number: "B-MATH1-01", submission_id: null, submission_seq: null, submission_state: null },
  submission: null,
  rejects_submission: false,
  resolved: null,
  ...over,
});

const item = (over: Record<string, unknown> = {}): QueueItem => {
  const q = parseQueue({ ok: true, items: [raw(over)], more: false });
  if (!q) throw new Error("not parsed");
  return q.items[0];
};

describe("parseQueue", () => {
  it("reads what script_exceptions_list answers", () => {
    const q = parseQueue({ ok: true, items: [raw()], more: true });
    expect(q?.more).toBe(true);
    const it0 = q!.items[0];
    expect(it0.kind).toBe("duplicate");
    expect(it0.page?.fullPath).toBe("e/u/6-full.jpg");
    expect(it0.page?.paperVersion).toBe(2);
    expect(it0.page?.areas).toEqual([{ x: 0.1, y: 0.05, w: 0.5, h: 0.04 }]);
    expect(it0.keptPage?.paperVersion).toBe(1);
    expect(it0.booking?.indexNumber).toBe("SE-2026-0001");
    expect(it0.upload?.batchNumber).toBe("B-MATH1-01");
    expect(it0.script?.number).toBe("S-MATH1-0001");
  });
  it("refuses a failure or a malformed answer, and skips malformed items", () => {
    expect(parseQueue({ ok: false, code: "forbidden" })).toBeNull();
    expect(parseQueue(null)).toBeNull();
    expect(parseQueue({ ok: true, items: "x" })).toBeNull();
    const q = parseQueue({ ok: true, items: [raw(), { id: 4 }, raw({ kind: "made_up" })], more: false });
    expect(q?.items).toHaveLength(1);
  });
  it("reads resolved items", () => {
    const r = item({ state: "resolved", resolved: { by: "Ada Admin", at: "2031-07-07T12:00:00Z", resolution: "kept", reason: "Sharper" } });
    expect(r.resolved).toEqual({ by: "Ada Admin", at: "2031-07-07T12:00:00Z", resolution: "kept", reason: "Sharper" });
  });
});

describe("foundInWords", () => {
  it("says what the server found, in plain words", () => {
    expect(foundInWords(item({ kind: "no_code", details: {} }))[0]).toBe("No code could be read on this page.");
    expect(foundInWords(item({ kind: "not_expected", details: { reason: "absent", copy_page: 2 } }))[0]).toContain("marked absent");
    expect(foundInWords(item({ kind: "not_expected", details: { reason: "other_booking", copy_page: 2 } }))[0]).toContain("another candidate");
    expect(foundInWords(item({ kind: "not_expected", details: { reason: "other_centre" } }))[0]).toContain("another centre");
    expect(foundInWords(item({ kind: "unknown_code", details: { code: "ABCDEFGH1", copy_page: 9 } }))[0]).toContain("ABCDEFGH1");
    expect(foundInWords(item({ kind: "other_exam", details: { copy_page: 3 } }))[0]).toContain("another exam");
    expect(foundInWords(item({ kind: "uncoded_family_page", details: { after_page: 4, from: "family" } }))[0]).toBe(
      "The family added a page with no code and said it follows page 4.",
    );
    expect(foundInWords(item({ kind: "missing_pages", details: { pages: [3, 4], dismissed: [2] } }))).toEqual([
      "Answer pages 3 and 4 have not arrived.",
      "Page 2 was confirmed as left blank.",
    ]);
    expect(foundInWords(item({ kind: "missing_pages", details: { pages: [], reason: "no_paper" } }))[0]).toContain("page roles");
    expect(foundInWords(item({ kind: "processing_failed", details: { kind: "prepare", attempts: 3 } }))[0]).toBe("The file could not be prepared after 3 attempts.");
    expect(foundInWords(item({ kind: "processing_failed", page: null, details: { kind: "remask", attempts: 3 } }))[0]).toBe(
      "The marking picture could not be made (this is not the family's file).",
    );
  });
  it("names both paper versions of a duplicate when they differ", () => {
    const words = foundInWords(item());
    expect(words[0]).toBe("Page 2 was scanned more than once. The clearer page was kept and this one set aside.");
    expect(words[1]).toBe("This page is from version 2 of the paper; the page kept is from version 1.");
  });
  it("describes poor quality and a page sent as it is", () => {
    const words = foundInWords(
      item({ kind: "poor_quality", details: { flags: ["blurred", "dark"], copy_page: 4, marking_picture: true, from: "family" } }),
    );
    expect(words[0]).toBe("Page 4 is blurred and too dark.");
    expect(words).toContain("The family sent it as it is instead of taking it again.");
    const layout = foundInWords(item({ kind: "poor_quality", details: { flags: ["layout_unexpected"], copy_page: 5, marking_picture: false } }));
    expect(layout.join(" ")).toContain("the name band could not be hidden");
    expect(layout.join(" ")).toContain("Hide the candidate's name");
  });
  it("describes a late hand-in", () => {
    const words = foundInWords(item({ kind: "late", details: { seq: 2 }, submission: { id: "x", seq: 2, state: "received", late: true, submitted_at: "2031-07-07T11:45:00Z" } }));
    expect(words[0]).toContain("Handed in late (submission 2");
  });
  it("lists the paper versions of a mixed script", () => {
    const words = foundInWords(
      item({
        kind: "mixed_versions",
        details: {},
        linked_pages: [
          { copy_page: 2, page: page({ paper_version: 1 }) },
          { copy_page: 3, page: page({ paper_version: 2 }) },
        ],
      }),
    );
    expect(words[0]).toBe("This script shows pages printed from two versions of the paper: page 2 is version 1; page 3 is version 2.");
  });
});

describe("actionsFor", () => {
  it("offers what fits each kind", () => {
    expect(actionsFor(item({ kind: "no_code" }))).toEqual(["hide_areas", "assign", "blank", "reject"]);
    expect(actionsFor(item({ kind: "unknown_code" }))).toEqual(["hide_areas", "assign", "blank", "reject"]);
    expect(actionsFor(item({ kind: "other_exam" }))).toEqual(["blank", "reject"]);
    expect(actionsFor(item())).toEqual(["keep_existing", "assign"]);
    expect(actionsFor(item({ kind: "uncoded_family_page" }))).toEqual(["hide_areas", "confirm", "assign", "blank", "reject"]);
    expect(actionsFor(item({ kind: "poor_quality" }))).toEqual(["hide_areas", "confirm", "reject"]);
    expect(actionsFor(item({ kind: "missing_pages", details: { pages: [3] } }))).toEqual(["dismiss_missing"]);
    expect(actionsFor(item({ kind: "missing_pages", details: { pages: [], reason: "no_paper" } }))).toEqual([]);
    expect(actionsFor(item({ kind: "mixed_versions" }))).toEqual(["confirm"]);
    expect(actionsFor(item({ kind: "late" }))).toEqual(["late_accept", "late_reject"]);
    expect(actionsFor(item({ kind: "late", script: null }))).toEqual([]);
    expect(actionsFor(item({ kind: "processing_failed", page: null, details: { kind: "prepare" } }))).toEqual(["confirm", "reject"]);
    expect(actionsFor(item({ kind: "processing_failed", page: null, details: { kind: "remask" } }))).toEqual(["confirm"]);
    // A page whose marking picture a remask could not make again is not the family's file: hide the name and accept it.
    expect(actionsFor(item({ kind: "poor_quality", details: { from: "remask", marking_picture: false } }))).toEqual(["hide_areas", "confirm"]);
  });
  it("offers nothing once resolved", () => {
    expect(actionsFor(item({ state: "resolved", resolved: { by: "A", at: "2031-07-07T12:00:00Z", resolution: "kept", reason: null } }))).toEqual([]);
  });
  it("labels the actions for home and centre", () => {
    expect(actionLabel("reject", item({ kind: "no_code" }))).toBe("Reject this page");
    expect(actionLabel("reject", item({ kind: "not_expected", upload: { ...raw().upload, source: "home" }, rejects_submission: true }))).toBe(
      "Reject the submission",
    );
    // A home page an upload already replaced: rejecting it rejects no submission, so the button does not say so.
    expect(actionLabel("reject", item({ kind: "poor_quality", upload: { ...raw().upload, source: "home" }, rejects_submission: false }))).toBe(
      "Reject this page",
    );
    expect(actionLabel("confirm", item({ kind: "processing_failed", page: null, details: { kind: "remask" } }))).toBe("Noted");
    expect(actionLabel("assign", item())).toBe("Use this page instead");
    expect(actionLabel("confirm", item({ kind: "poor_quality" }))).toBe("Accept as it is");
  });
});

describe("reasonProblem", () => {
  it("needs 3 to 300 characters once trimmed", () => {
    expect(reasonProblem("  ab ", true)).toBe("Give a reason of 3 to 300 characters.");
    expect(reasonProblem("", true)).toBe("Give a reason of 3 to 300 characters.");
    expect(reasonProblem("abc", true)).toBeNull();
    expect(reasonProblem("x".repeat(300), true)).toBeNull();
    expect(reasonProblem("x".repeat(301), true)).toBe("Give a reason of 3 to 300 characters.");
  });
  it("may be left empty when optional, but not too short", () => {
    expect(reasonProblem("  ", false)).toBeNull();
    expect(reasonProblem("ab", false)).toBe("Give a reason of 3 to 300 characters.");
  });
});

describe("rpcFor", () => {
  it("names the function and its arguments, with the reason trimmed", () => {
    expect(rpcFor({ action: "assign", exceptionId: "e", bookingId: "b", copyPage: 4, reason: " Torn code " })).toEqual({
      fn: "script_exception_assign",
      args: { p_exception: "e", p_booking: "b", p_copy_page: 4, p_reason: "Torn code" },
    });
    expect(rpcFor({ action: "keep_existing", exceptionId: "e", reason: "Sharper" })).toEqual({
      fn: "script_exception_keep_existing",
      args: { p_exception: "e", p_reason: "Sharper" },
    });
    expect(rpcFor({ action: "confirm", exceptionId: "e", reason: "  " })).toEqual({ fn: "script_exception_confirm", args: { p_exception: "e" } });
    expect(rpcFor({ action: "confirm", exceptionId: "e", reason: "", noName: true })).toEqual({
      fn: "script_exception_confirm",
      args: { p_exception: "e", p_no_name: true },
    });
    expect(rpcFor({ action: "assign", exceptionId: "e", bookingId: "b", copyPage: 2, reason: "Real page 2", replace: true }).args).toEqual({
      p_exception: "e",
      p_booking: "b",
      p_copy_page: 2,
      p_reason: "Real page 2",
      p_replace: true,
    });
    expect(rpcFor({ action: "assign", exceptionId: "e", bookingId: "b", copyPage: 5, reason: "No name on it", noName: true }).args).toEqual({
      p_exception: "e",
      p_booking: "b",
      p_copy_page: 5,
      p_reason: "No name on it",
      p_no_name: true,
    });
    expect(rpcFor({ action: "dismiss_missing", exceptionId: "e", pages: [3, 4], reason: "Blank" })).toEqual({
      fn: "script_exception_dismiss_missing",
      args: { p_exception: "e", p_pages: [3, 4], p_reason: "Blank" },
    });
    expect(rpcFor({ action: "late_reject", scriptId: "s", reason: "Too late" })).toEqual({
      fn: "script_late_decide",
      args: { p_script: "s", p_accept: false, p_reason: "Too late" },
    });
  });
});

describe("words", () => {
  it("labels kinds and resolutions", () => {
    expect(KIND_LABEL.uncoded_family_page).toBe("Page added by the family");
    expect(resolutionLabel("dismissed")).toBe("Confirmed left blank");
    expect(resolutionLabel("something_new")).toBe("something_new");
  });
  it("says why an assignment or a changed page was refused", () => {
    expect(conflictMessage({ reason: "occupied" })).toContain("already holds a page");
    expect(conflictMessage({ reason: "changed" })).toBe("This page changed while you were working. Refresh the page and try again.");
  });
  it("says who resolved it first", () => {
    expect(conflictMessage({ resolved_by: "Ada Admin", resolved_at: "2031-07-07T11:00:00Z" })).toMatch(/^Already resolved by Ada Admin on .+\. Refresh the page\.$/);
    expect(conflictMessage({})).toBe("This has already been resolved. Refresh the page to see how.");
  });
});

describe("needsNameCheck", () => {
  it("asks for a hidden area or 'no name' on a page whose layout was unexpected, and for a visible name", () => {
    const layout = page({ quality: { sharpness: 100, brightness: 180, cut_off: false, flags: ["layout_unexpected"] }, areas: [] });
    expect(needsNameCheck(item({ kind: "poor_quality", page: layout }))).toBe(true);
    expect(needsNameCheck(item({ kind: "poor_quality", page: { ...layout, areas: [{ x: 0.1, y: 0.1, w: 0.2, h: 0.1 }] } }))).toBe(false);
    expect(needsNameCheck(item({ kind: "poor_quality", page: page({ quality: { flags: ["blurred"] }, areas: [] }) }))).toBe(false);
    expect(needsNameCheck(item({ kind: "name_visible", page: page({ areas: [] }) }))).toBe(true);
    expect(needsNameCheck(item({ kind: "uncoded_family_page" }))).toBe(false); // an area is drawn on it already
  });
  it("asks for it on a page with no code that staff assign or accept (Ruling R31)", () => {
    const codeless = page({ copy_page: null, paper_version: null, paper_current: null, areas: [] });
    expect(needsNameCheck(item({ kind: "no_code", page: codeless }), "assign")).toBe(true);
    expect(needsNameCheck(item({ kind: "unknown_code", page: { ...codeless, copy_page: 2 } }), "assign")).toBe(true);
    expect(needsNameCheck(item({ kind: "no_code", page: { ...codeless, areas: [{ x: 0.1, y: 0.1, w: 0.2, h: 0.1 }] } }), "assign")).toBe(false);
    expect(needsNameCheck(item({ kind: "not_expected", page: page({ areas: [] }) }), "assign")).toBe(false); // it has a code
    expect(needsNameCheck(item({ kind: "uncoded_family_page", page: codeless }), "assign")).toBe(true);
    expect(needsNameCheck(item({ kind: "uncoded_family_page", page: codeless }))).toBe(true);
    expect(needsNameCheck(item({ kind: "poor_quality", page: codeless }))).toBe(true);
    expect(needsNameCheck(item({ kind: "poor_quality", page: page({ areas: [] }), details: { from: "remask" } }))).toBe(true);
    expect(needsNameCheck(item({ kind: "no_code", page: codeless }), "blank")).toBe(false);
  });
});

describe("a page whose marking picture a remask could not make again", () => {
  it("says it is not the family's file and what to do", () => {
    const words = foundInWords(item({ kind: "poor_quality", details: { from: "remask", marking_picture: false, flags: [] } }));
    expect(words.join(" ")).toContain("not the family's file");
    expect(words.join(" ")).toContain("Hide the candidate's name");
  });
});

describe("resolvedMessage", () => {
  it("says what actually happened", () => {
    expect(resolvedMessage({ action: "reject", exceptionId: "e", reason: "r" }, { outcome: "submission_rejected" })).toBe(
      "Rejected. The family's submission is rejected and they have been emailed with your reason.",
    );
    expect(resolvedMessage({ action: "reject", exceptionId: "e", reason: "r" }, { outcome: "set_aside" })).toBe("Rejected. The page is set aside.");
    expect(resolvedMessage({ action: "reject", exceptionId: "e", reason: "r" }, { outcome: "closed" })).toContain("nothing else changed");
    expect(resolvedMessage({ action: "late_reject", scriptId: "s", reason: "r" }, { outcome: "on_time_used" })).toMatch(
      /^The late upload is set aside; the on-time pages are used\./,
    );
    expect(resolvedMessage({ action: "late_reject", scriptId: "s", reason: "r" }, { outcome: "void" })).toContain("void");
    expect(resolvedMessage({ action: "assign", exceptionId: "e", bookingId: "b", copyPage: 2, reason: "r" }, { replaced_page_id: "p" })).toContain(
      "kept for review as a duplicate",
    );
  });
});

describe("failureMessage", () => {
  it("names another family, a conflict, or the code's message", () => {
    expect(failureMessage({ code: "forbidden", reason: "other_family" })).toContain("another family");
    expect(failureMessage({ code: "forbidden" })).toBe("You do not have permission to do that.");
    expect(failureMessage({ code: "conflict", resolved_by: "Ada Admin", resolved_at: "2031-07-07T11:00:00Z" })).toContain("Ada Admin");
    expect(failureMessage({ code: "still_mixed" })).toContain("two versions");
  });
});

describe("parseCandidates", () => {
  it("reads what script_exception_candidates answers", () => {
    const c = parseCandidates({
      ok: true,
      candidates: [
        { booking_id: "b", name: "Sam Pupil", index_number: "SE-2026-0001", sitting: "centre", status: "paid", attendance: "present", script_number: "S-1", pages: [2, 3], copy_pages: 6 },
        { booking_id: 5 },
      ],
    });
    expect(c).toEqual([
      { bookingId: "b", name: "Sam Pupil", indexNumber: "SE-2026-0001", sitting: "centre", status: "paid", attendance: "present", scriptNumber: "S-1", pages: [2, 3], copyPages: 6 },
    ]);
    expect(parseCandidates({ ok: false, code: "invalid_input" })).toBeNull();
  });
});
