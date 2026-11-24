import { describe, expect, it } from "vitest";
import { blockText, checkLines, figureLines, noteProblem, parseApproval, scriptLines, STALE_TEXT, type ApprovalFigures } from "./marking-approval";

const answer = {
  ok: true,
  approved_at: "2026-12-03T10:15:00+00:00",
  approved_by_name: "Agatha Approver",
  opened: true,
  can_approve: false,
  stale: true,
  blocks: [
    { code: "scripts_not_checked", count: 3, with_staff: 1 },
    { code: "with_lead", count: 2 },
    { code: "something_new", count: 4 },
    { code: "waiting_second", count: 0 },
  ],
  scripts: { checked: 12, withdrawn: 1, void: 0, other: 3 },
  no_script: 2,
  checks: {
    double_marking: false,
    sample_percent: 10,
    tolerance_percent: 10,
    seeds: false,
    seed_every: 10,
    practice: false,
    off: { reason: "Only one marker this term.", by_name: "Agatha Approver", at: "2026-11-20T09:00:00+00:00" },
  },
  lead_name: null,
  figures: {
    pieces: 11,
    second_marked: 5,
    within_tolerance: 1,
    settled: { first_stands: 2, second_stands: 1, lead_marks: 1 },
    settled_by_a_party: 1,
    accepted_after_pause: 1,
    sent_back: 1,
    final_marks_changed: 1,
    standards: { practice: 1, seed: 1 },
    seed_attempts: 2,
    seed_outside: 1,
    sample_reviews_open: 1,
  },
  index_number: "SE-2099-0001",
};

describe("parseApproval", () => {
  it("approval_parse_keeps_the_known_fields", () => {
    const r = parseApproval(answer);
    expect(r?.ok).toBe(true);
    if (!r || !r.ok) return;
    const a = r.approval;
    expect(a.approvedByName).toBe("Agatha Approver");
    expect(a.stale).toBe(true);
    expect(a.canApprove).toBe(false);
    expect(a.blocks).toEqual([
      { code: "scripts_not_checked", count: 3, withStaff: 1 },
      { code: "with_lead", count: 2, withStaff: 0 },
    ]);
    expect(a.scripts).toEqual({ checked: 12, withdrawn: 1, void: 0, other: 3 });
    expect(a.noScript).toBe(2);
    expect(a.checks.off).toEqual({ reason: "Only one marker this term.", byName: "Agatha Approver", at: "2026-11-20T09:00:00+00:00" });
    expect(a.leadName).toBeNull();
    expect(a.figures.settled).toEqual({ firstStands: 2, secondStands: 1, leadMarks: 1 });
    expect(a.figures.seedOutside).toBe(1);
    expect(JSON.stringify(a)).not.toContain("SE-2099");
  });
  it("approval_parse_refusals", () => {
    expect(parseApproval({ ok: false, code: "forbidden" })).toEqual({ ok: false, code: "forbidden" });
    expect(parseApproval({ ok: false })).toEqual({ ok: false, code: "internal" });
    expect(parseApproval(null)).toBeNull();
    expect(parseApproval([])).toBeNull();
    expect(parseApproval({ ok: true })).toBeNull();
  });
});

describe("blockText", () => {
  it("block_texts", () => {
    expect(blockText({ code: "with_lead", count: 3, withStaff: 0 })).toBe("3 scripts are with the lead marker.");
    expect(blockText({ code: "with_lead", count: 1, withStaff: 0 })).toBe("1 script is with the lead marker.");
    expect(blockText({ code: "waiting_second", count: 2, withStaff: 0 })).toBe("2 scripts wait for a second marker.");
    expect(blockText({ code: "waiting_second", count: 1, withStaff: 0 })).toBe("1 script waits for a second marker.");
    expect(blockText({ code: "scripts_not_checked", count: 1, withStaff: 1 })).toBe("1 script is still with staff.");
    expect(blockText({ code: "scripts_not_checked", count: 4, withStaff: 0 })).toBe("4 scripts are not checked yet.");
    expect(blockText({ code: "scripts_not_checked", count: 4, withStaff: 1 })).toBe("4 scripts are not checked yet, 1 of them still with staff.");
    expect(blockText({ code: "on_hold", count: 1, withStaff: 0 })).toBe("1 script is on hold.");
    expect(blockText({ code: "alerts_open", count: 2, withStaff: 0 })).toBe("2 alerts need attention.");
    expect(blockText({ code: "alerts_open", count: 1, withStaff: 0 })).toBe("1 alert needs attention.");
    expect(blockText({ code: "pictures_to_check", count: 1, withStaff: 0 })).toBe("1 script has a marking picture for staff to check.");
    expect(blockText({ code: "pictures_to_check", count: 2, withStaff: 0 })).toBe("2 scripts have marking pictures for staff to check.");
    expect(blockText({ code: "pause_pending", count: 1, withStaff: 0 })).toBe("1 paused marker's scripts have not gone to the lead marker yet.");
  });
});

describe("the page's lines", () => {
  it("script_lines", () => {
    expect(scriptLines({ scripts: { checked: 12, withdrawn: 1, void: 0, other: 0 }, noScript: 2 })).toEqual([
      "12 checked",
      "1 withdrawn",
      "0 void",
      "2 candidates have no script",
    ]);
    expect(scriptLines({ scripts: { checked: 1, withdrawn: 0, void: 0, other: 0 }, noScript: 1 })[3]).toBe("1 candidate has no script");
  });
  it("check_lines", () => {
    expect(checkLines({ doubleMarking: true, samplePercent: 10, tolerancePercent: 15, seeds: true, seedEvery: 12, practice: true, off: null })).toEqual([
      "Double marking: second-mark 10% of scripts, and send to the lead marker when marks differ by more than 15% of the maximum.",
      "Seeded scripts: about one in every 12 scripts.",
      "Practice before live marking: on.",
    ]);
    expect(checkLines({ doubleMarking: false, samplePercent: 10, tolerancePercent: 10, seeds: false, seedEvery: 10, practice: false, off: null })).toEqual([
      "Double marking: off.",
      "Seeded scripts: off.",
      "Practice before live marking: off.",
    ]);
  });
  it("figure_lines", () => {
    const f: ApprovalFigures = {
      pieces: 11,
      secondMarked: 5,
      withinTolerance: 1,
      settled: { firstStands: 2, secondStands: 1, leadMarks: 1 },
      settledByAParty: 1,
      acceptedAfterPause: 1,
      sentBack: 1,
      finalMarksChanged: 1,
      standards: { practice: 1, seed: 1 },
      seedAttempts: 2,
      seedOutside: 1,
      sampleReviewsOpen: 1,
    };
    expect(figureLines(f)).toEqual([
      "Second-marked: 5 of 11 scripts, 1 within tolerance.",
      "Differences settled: 4 (First marks stand 2, Second marks stand 1, the lead marker's own marks 1).",
      "Settled by a lead marker who was one of the two markers: 1.",
      "Accepted after a marker was paused: 1.",
      "Sent back: 1.",
      "Final marks changed by the lead marker: 1 script.",
      "Seeded scripts: 1, with 2 attempts, 1 outside tolerance.",
      "Practice scripts: 1.",
      "Routine samples still open: 1. They do not block approval.",
    ]);
    const none = figureLines({ ...f, settled: { firstStands: 0, secondStands: 0, leadMarks: 0 }, settledByAParty: 0, standards: { practice: 0, seed: 0 }, sampleReviewsOpen: 0 });
    expect(none).toContain("Differences settled: none.");
    expect(none).toContain("Seeded scripts: none.");
    expect(none.some((l) => l.startsWith("Settled by") || l.startsWith("Routine"))).toBe(false);
    expect(figureLines({ ...f, settledByAParty: 0 })).toContain("Settled by a lead marker who was one of the two markers: 0.");
  });
  it("stale_text_and_note", () => {
    expect(STALE_TEXT).toBe("A script arrived after this approval. Withdraw the approval to include it.");
    expect(noteProblem("")).toBeNull();
    expect(noteProblem("x".repeat(300))).toBeNull();
    expect(noteProblem("x".repeat(301))).toBe("A note can be up to 300 characters.");
  });
});
