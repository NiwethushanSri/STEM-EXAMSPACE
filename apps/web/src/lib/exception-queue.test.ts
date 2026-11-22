import { describe, expect, it } from "vitest";
import {
  KIND_LABEL,
  MARKING_CHECK_NOTE,
  NAME_SHOWS_MESSAGE,
  actionLabel,
  actionsFor,
  asksMarkingCheck,
  checkTitle,
  conflictMessage,
  failureMessage,
  foundInWords,
  markingCheckedMessage,
  markingCheckFailure,
  NAME_BOX_MESSAGE,
  needsMarkingCheck,
  needsNameCheck,
  noNameOffered,
  parseCandidates,
  parseMarkingChecks,
  parseQueue,
  reasonProblem,
  resolutionLabel,
  resolvedMessage,
  resolvedNote,
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
    // A file of too many pages is not read at all (Ruling R40): staff are told to split it.
    const tooMany = foundInWords(item({ kind: "processing_failed", details: { kind: "prepare", attempts: 1, reason: "too_many_pages" } }));
    expect(tooMany[0]).toBe("The file has more than 5,000 pages, so it was not read.");
    expect(tooMany.join(" ")).toContain("about 500 pages");
    expect(foundInWords(item({ kind: "processing_failed", page: null, details: { kind: "remask", attempts: 3 } }))[0]).toBe(
      "The marking pictures could not be made (this is not the family's file), so the file's old ones were taken away.",
    );
  });
  it("names both paper versions of a duplicate when they differ", () => {
    const words = foundInWords(item());
    expect(words[0]).toBe("Page 2 was scanned more than once. The clearer page was kept and this one set aside.");
    expect(words[1]).toBe("This page is from version 2 of the paper; the page kept is from version 1.");
  });
  it("says when a page was left out because another script shows it", () => {
    const words = foundInWords(item({ details: { copy_page: 3, reason: "in_other_script", other_script_id: "s-2" } }));
    expect(words[0]).toBe("Page 3 is already in another candidate's script, so it was left out of this one.");
    expect(words[1]).toContain("one script only");
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
    expect(actionLabel("confirm", item({ kind: "processing_failed", page: null, details: { kind: "remask" } }))).toBe("Make the marking pictures again");
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
    expect(resolutionLabel("marking_made")).toBe("Marking picture made");
    expect(resolutionLabel("processed")).toBe("File processed again");
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

describe("noNameOffered (Ruling R40)", () => {
  const layout = page({ quality: { sharpness: 100, brightness: 180, cut_off: false, flags: ["layout_unexpected"] }, areas: [] });
  const codeless = page({ copy_page: null, paper_version: null, paper_current: null, areas: [] });
  it("hides the 'no name' tick for a page with a code, and says why", () => {
    expect(needsNameCheck(item({ kind: "poor_quality", page: layout }))).toBe(true);
    expect(noNameOffered(item({ kind: "poor_quality", page: layout }))).toBe(false);
    expect(noNameOffered(item({ kind: "name_visible", page: page({ areas: [] }) }))).toBe(false);
    expect(noNameOffered(item({ kind: "poor_quality", page: page({ areas: [] }), details: { from: "remask" } }))).toBe(false);
    expect(NAME_BOX_MESSAGE).toBe("This page has a printed name box. Draw a box over the name before confirming.");
  });
  it("still offers it for a page with no code", () => {
    expect(noNameOffered(item({ kind: "no_code", page: codeless }), "assign")).toBe(true);
    expect(noNameOffered(item({ kind: "uncoded_family_page", page: codeless }))).toBe(true);
    expect(noNameOffered(item({ kind: "poor_quality", page: codeless }))).toBe(true);
    expect(noNameOffered(item({ kind: "no_code", page: { ...codeless, areas: [{ x: 0.1, y: 0.1, w: 0.2, h: 0.1 }] } }), "assign")).toBe(false);
  });
});

describe("a page whose marking picture a remask could not make again", () => {
  it("says it is not the family's file and what to do", () => {
    const words = foundInWords(item({ kind: "poor_quality", details: { from: "remask", marking_picture: false, flags: [] } }));
    expect(words.join(" ")).toContain("not the family's file");
    expect(words.join(" ")).toContain("Hide the candidate's name");
    // A page with a code is only ever made from its print layout (Ruling R32).
    expect(words.join(" ")).toContain("process its file again");
  });
  it("says a script being marked kept a marking picture that may be out of date", () => {
    const words = foundInWords(item({ kind: "poor_quality", details: { from: "remask", marking_picture: true, stale_marking: true, flags: [] } }));
    expect(words.join(" ")).toContain("may be out of date");
  });
  it("never offers to hide a name where it could not be hidden, and says what to do instead (R34 d)", () => {
    const stale = item({ kind: "poor_quality", details: { from: "remask", marking_picture: true, stale_marking: true, flags: [] } });
    expect(actionsFor(stale)).toEqual(["confirm"]);
    expect(actionLabel("confirm", stale)).toBe("Noted");
    expect(needsNameCheck(stale)).toBe(false);
    expect(foundInWords(stale).join(" ")).toContain("marking lead");
    const marking = { ...raw().script, state: "marking" };
    const locked = item({ kind: "name_visible", script: marking, page: page({ areas: [] }) });
    expect(actionsFor(locked)).not.toContain("hide_areas");
    expect(foundInWords(locked).join(" ")).toContain("can no longer change here");
    expect(actionsFor(item({ kind: "name_visible" }))).toContain("hide_areas");
  });
  it("says being marked only of a script that is being marked, not one withdrawn or void (R35)", () => {
    for (const state of ["ready_to_mark", "marking", "marked", "checked", "final"]) {
      const marking = item({ kind: "name_visible", script: { ...raw().script, state }, page: page({ areas: [] }) });
      expect(foundInWords(marking).join(" ")).toContain("is being marked");
      expect(actionsFor(marking)).not.toContain("hide_areas");
    }
    const withdrawn = item({ kind: "name_visible", script: { ...raw().script, state: "withdrawn" }, page: page({ areas: [] }) });
    expect(foundInWords(withdrawn).join(" ")).not.toContain("being marked");
    expect(foundInWords(withdrawn).join(" ")).toContain("The script is withdrawn");
    // The database still refuses hidden areas there, so they are still not offered.
    expect(actionsFor(withdrawn)).not.toContain("hide_areas");
    const voided = item({ kind: "poor_quality", script: { ...raw().script, state: "void" }, page: page({ areas: [] }), details: { flags: ["blurred"] } });
    expect(foundInWords(voided).join(" ")).not.toContain("being marked");
    expect(foundInWords(voided).join(" ")).toContain("The script is void");
    expect(foundInWords(item({ kind: "name_visible" })).join(" ")).not.toContain("The script is");
  });
  it("offers for a check left on a replaced page only what the database allows (R35)", () => {
    const gone = page({ areas: [], replaced: true });
    const check = item({ kind: "poor_quality", page: gone, details: { from: "remask", marking_picture: false, flags: [] } });
    expect(actionsFor(check)).toEqual(["confirm"]);
    expect(foundInWords(check).join(" ")).toContain("this page was replaced");
    const family = item({ kind: "uncoded_family_page", page: gone, details: { after_page: 2 } });
    expect(actionsFor(family)).not.toContain("hide_areas");
    expect(actionsFor(family)).not.toContain("assign");
    expect(actionsFor(family)).toContain("confirm");
    const current = item({ kind: "uncoded_family_page", page: page({ areas: [] }), details: { after_page: 2 } });
    expect(actionsFor(current)).toEqual(expect.arrayContaining(["hide_areas", "assign"]));
    expect(foundInWords(current).join(" ")).not.toContain("was replaced");
  });
  it("says a page read for a script being marked was not added to it (R35)", () => {
    const words = foundInWords(item({ kind: "not_expected", details: { reason: "script_locked", copy_page: 3 } }));
    expect(words.join(" ")).toContain("already being marked");
    expect(words.join(" ")).toContain("not added to the script");
  });
  it("asks for the name to be checked again after reprocessing", () => {
    const words = foundInWords(item({ kind: "poor_quality", details: { from: "remask", marking_picture: false, reprocessed: true, flags: [] } }));
    expect(words.join(" ")).toContain("Check the name again after reprocessing");
  });
  it("says noting a remask failure makes the marking pictures again", () => {
    const words = foundInWords(item({ kind: "processing_failed", page: null, details: { kind: "remask", attempts: 3 } }));
    expect(words.join(" ")).toContain("made again");
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

describe("marking pictures to check (Phase 3A Task 8)", () => {
  const check = (over: Record<string, unknown> = {}) => ({
    page_id: "11111111-1111-4111-8111-111111111111",
    exam_id: "55555555-5555-4555-8555-555555555555",
    script_number: "S-MATH1-0001",
    booking: { id: "66666666-6666-4666-8666-666666666666", name: "Sam Pupil", index_number: "SE-2026-0001", sitting: "home", status: "paid" },
    copy_page: 2,
    full_path: "e/u/1-full.jpg",
    marking_path: "e/u/7-1/1-marking.jpg",
    ...over,
  });

  it("reads what script_marking_checks_list answers, and skips malformed items", () => {
    const c = parseMarkingChecks({ ok: true, items: [check(), check({ page_id: null }), check({ marking_path: "" }), 4] });
    expect(c?.items).toEqual([
      {
        pageId: "11111111-1111-4111-8111-111111111111",
        examId: "55555555-5555-4555-8555-555555555555",
        scriptNumber: "S-MATH1-0001",
        booking: { id: "66666666-6666-4666-8666-666666666666", name: "Sam Pupil", indexNumber: "SE-2026-0001", sitting: "home", status: "paid" },
        copyPage: 2,
        fullPath: "e/u/1-full.jpg",
        markingPath: "e/u/7-1/1-marking.jpg",
      },
    ]);
    expect(parseMarkingChecks({ ok: false, code: "forbidden" })).toBeNull();
    expect(parseMarkingChecks({ ok: true, items: "x" })).toBeNull();
  });

  it("counts the pages that wait, once each", () => {
    const c = parseMarkingChecks({ ok: true, items: [check(), check({ page_id: "22222222-2222-4222-8222-222222222222", copy_page: null }), check()] })!;
    expect(needsMarkingCheck(c.items)).toBe(2);
    expect(needsMarkingCheck([])).toBe(0);
  });

  it("names the script and its page, or a page the family added", () => {
    const [a, b] = parseMarkingChecks({ ok: true, items: [check(), check({ copy_page: null })] })!.items;
    expect(checkTitle(a)).toBe("Script S-MATH1-0001, page 2");
    expect(checkTitle(b)).toBe("Script S-MATH1-0001, a page the family added");
  });

  it("after an accept, says where to check the marking picture", () => {
    expect(MARKING_CHECK_NOTE).toBe("Accepted. When the marking picture is made, check it under Marking pictures to check.");
    const quality = item({ kind: "poor_quality", details: { flags: ["layout_unexpected"], copy_page: 2 } });
    expect(asksMarkingCheck(quality, "confirm")).toBe(true);
    expect(resolvedNote(quality, "confirm", "Confirmed.")).toBe(MARKING_CHECK_NOTE);
    expect(resolvedNote(item({ kind: "name_visible", details: {} }), "confirm", "Confirmed.")).toBe(MARKING_CHECK_NOTE);
    expect(resolvedNote(item({ kind: "uncoded_family_page", details: {} }), "confirm", "Confirmed.")).toBe(MARKING_CHECK_NOTE);
    expect(resolvedNote(item({ kind: "no_code", details: {} }), "assign", "Assigned. The page is in the candidate's script.")).toBe(
      "Assigned. The page is in the candidate's script. When the marking picture is made, check it under Marking pictures to check.",
    );
  });

  it("says nothing more when the page needs no check", () => {
    expect(resolvedNote(item(), "keep_existing", "Kept the page already chosen.")).toBe("Kept the page already chosen.");
    expect(resolvedNote(item({ kind: "not_expected", details: {} }), "assign", "Assigned.")).toBe("Assigned.");
    expect(resolvedNote(item({ kind: "poor_quality", details: {} }), "reject", "Rejected.")).toBe("Rejected.");
    expect(resolvedNote(item({ kind: "mixed_versions", details: {}, page: null }), "confirm", "Confirmed.")).toBe("Confirmed.");
    expect(resolvedNote(item({ kind: "poor_quality", details: { from: "remask", stale_marking: true } }), "confirm", "Confirmed.")).toBe("Confirmed.");
    expect(asksMarkingCheck(item({ kind: "processing_failed", details: { kind: "remask" }, page: null }), "confirm")).toBe(false);
  });

  it("says why a check was refused", () => {
    expect(markingCheckFailure({ code: "conflict", reason: "changed" })).toContain("changed since it was shown");
    expect(markingCheckFailure({ code: "conflict", reason: "pictures_updating" })).toContain("being made again");
    expect(markingCheckFailure({ code: "conflict", reason: "name_visible" })).toContain("Hide it under Problems first");
    expect(markingCheckFailure({ code: "conflict", reason: "not_needed" })).toContain("needs no check");
    expect(markingCheckFailure({ code: "conflict" })).toContain("changed since it was shown");
    expect(markingCheckFailure({ code: "forbidden" })).toBe("You do not have permission to do that.");
    expect(markingCheckFailure({ code: "reason_required" })).toBe("Give a reason of 3 to 300 characters.");
  });

  it("says what a check did", () => {
    expect(markingCheckedMessage("verified")).toBe("Checked. The name is hidden, and the script is verified.");
    expect(markingCheckedMessage("needs_attention")).toBe("Checked. The name is hidden.");
    expect(NAME_SHOWS_MESSAGE).toContain('under Problems as "Name visible"');
  });

  it("says when staff saw a name on a marking picture", () => {
    expect(foundInWords(item({ kind: "name_visible", details: { from: "staff_check" } }))[0]).toBe(
      "Staff saw a name on this page's marking picture. Hide it, then confirm.",
    );
    expect(foundInWords(item({ kind: "name_visible", details: { from: "marker" } }))[0]).toContain("A marker reported");
  });
});
