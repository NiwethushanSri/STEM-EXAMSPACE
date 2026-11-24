import { describe, expect, it } from "vitest";
import {
  checkStateText,
  clearanceText,
  changedMarks,
  noteProblem,
  parseExamMarkers,
  parseReviewList,
  parseReviewOpen,
  parseStandards,
  readMarks,
  reviewRows,
  stuckText,
  type ReviewCompare,
} from "./marking-review";

const Q1 = "11111111-1111-4111-8111-111111111111";
const Q2 = "22222222-2222-4222-8222-222222222222";
const Q3 = "33333333-3333-4333-8333-333333333333";

describe("checkStateText", () => {
  it("check_state_text_cases", () => {
    expect(checkStateText("waiting_second")).toBe("Waiting for a second marker");
    expect(checkStateText("to_lead", "difference")).toBe("With the lead marker: marks differ");
    expect(checkStateText("to_lead", "paused_marker")).toBe("With the lead marker: marker paused");
    expect(checkStateText("to_lead")).toBe("With the lead marker");
    expect(checkStateText("checked")).toBe("Checked");
    expect(checkStateText(null)).toBe("");
    expect(checkStateText("something_new")).toBe("");
  });
});

const compare = (questions: ReviewCompare["questions"]): ReviewCompare => ({ within: false, totalA: 9, totalB: 14, maxTotal: 20, questions });

describe("reviewRows", () => {
  it("review_rows_flag_questions_outside_tolerance", () => {
    const rows = reviewRows(
      compare([
        { questionId: Q1, label: "1(a)", max: 4, a: 3, aNa: false, b: 3, bNa: false, out: false },
        { questionId: Q2, label: "1(b)", max: 6, a: 1, aNa: false, b: 6, bNa: false, out: true },
        { questionId: Q3, label: "2", max: 10, a: 5, aNa: false, b: 5, bNa: false, out: false },
      ]),
      [
        { questionId: Q1, mark: 3, na: false, source: "first" },
        { questionId: Q2, mark: 4, na: false, source: "lead" },
      ],
    );
    expect(rows.map((r) => r.out)).toEqual([false, true, false]);
    expect(rows[1]).toEqual({ label: "1(b)", max: 6, first: "1", second: "6", final: "4", out: true });
    // A question with no final mark yet shows a dash.
    expect(rows[2].final).toBe("–");
  });
  it("review_rows_show_nr_and_half_marks", () => {
    const rows = reviewRows(
      compare([
        { questionId: Q1, label: "1", max: 3, a: 2.5, aNa: false, b: null, bNa: true, out: true },
        { questionId: Q2, label: "2", max: 3, a: null, aNa: true, b: 0.5, bNa: false, out: false },
      ]),
      [
        { questionId: Q1, mark: null, na: true, source: "lead" },
        { questionId: Q2, mark: 1.5, na: false, source: "lead" },
      ],
    );
    expect(rows[0]).toMatchObject({ first: "2.5", second: "NR", final: "NR" });
    expect(rows[1]).toMatchObject({ first: "NR", second: "0.5", final: "1.5" });
  });
});

describe("parseReviewList", () => {
  it("reads the counts and the items, and keeps no other field", () => {
    const r = parseReviewList({
      ok: true,
      counts: { difference: 2, paused_marker: 1, sample: 0, to_clear: 3, stuck_second: 4 },
      items: [
        {
          review_id: "r1",
          kind: "difference",
          exam_id: "e1",
          exam_title: "Physics mock",
          unit_id: "u1",
          script_number: "P1-0007",
          index_number: "SE-2026-0001",
          group_label: null,
          first: { marker_id: "m1", name: "Ann Marker", total: 9 },
          second: { marker_id: "m2", name: "Bob Marker", total: 14 },
          max_total: 20,
          opened_at: "2026-12-01T10:00:00Z",
          party: true,
          last_name: "Quarterfield",
        },
        { review_id: "r2", kind: "unknown_kind", exam_id: "e1", unit_id: "u2", first: { marker_id: "m1" } },
      ],
      more: false,
    });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.list.counts).toEqual({ difference: 2, pausedMarker: 1, sample: 0, toClear: 3, stuckSecond: 4 });
    expect(r.list.items).toHaveLength(1);
    expect(r.list.items[0]).toMatchObject({ reviewId: "r1", party: true, first: { name: "Ann Marker", total: 9 }, second: { name: "Bob Marker", total: 14 } });
    expect(JSON.stringify(r)).not.toContain("Quarterfield");
    expect(parseReviewList({ ok: false, code: "forbidden" })).toEqual({ ok: false, code: "forbidden" });
  });
  it("the stuck line counts the scripts", () => {
    expect(stuckText(3)).toBe("3 scripts wait for a second marker and nobody can take them. Assign one on the Marking page, or release them with a reason.");
    expect(stuckText(1)).toBe("1 script waits for a second marker and nobody can take it. Assign one on the Marking page, or release it with a reason.");
  });
});

const marking = (id: string, marks: unknown[], extra: Record<string, unknown> = {}) => ({
  marking_id: id,
  rev: 4,
  marker_name: "Ann Marker",
  total: 9,
  lead_note: "Check 1(b).",
  active_seconds: 300,
  submitted_at: "2026-12-01T10:00:00Z",
  marks,
  annotations: [{ id: "a1", page_id: "p1", kind: "tick", x: 0.5, y: 0.5, points: null, text: null, question_id: Q1 }],
  ...extra,
});
const opened = (second: unknown, compareSet: unknown) => ({
  ok: true,
  review: { id: "r1", kind: second ? "difference" : "paused_marker", state: "open", outcome: null, party: false },
  unit: { id: "u1", exam_title: "Physics mock", paper: "Paper 1", script_number: "P1-0007", index_number: "SE-2026-0001", group_label: null, first_name: "Jo" },
  structure: {
    questions: [
      { id: "top", parent_id: null, label: "1", position: 1, max_mark: null, mark_step: 1, option_group_id: null },
      { id: Q1, parent_id: "top", label: "a", position: 1, max_mark: 4, mark_step: 1, option_group_id: null },
      { id: Q2, parent_id: "top", label: "b", position: 2, max_mark: 6, mark_step: 0.5, option_group_id: null },
    ],
    option_groups: [],
  },
  pages: [{ n: 1, page_id: "p1", copy_page: 1, extra: false, rotation: 0 }],
  first: marking("f1", [
    { question_id: Q1, mark: 3, na: false },
    { question_id: Q2, mark: 1, na: false },
  ]),
  second,
  compare: compareSet,
  final: [],
});

describe("parseReviewOpen", () => {
  it("reads both markings and their comparison, and keeps no name but the markers'", () => {
    const r = parseReviewOpen(
      opened(marking("s1", [{ question_id: Q1, mark: 3, na: false }, { question_id: Q2, mark: 6, na: false }], { marker_name: "Bob Marker", rev: 2 }), {
        within: false,
        total_a: 4,
        total_b: 9,
        total_tolerance: 1,
        max_total: 10,
        questions: [
          { question_id: Q1, label: "1(a)", max: 4, a: 3, a_na: false, b: 3, b_na: false, tolerance: 1, out: false },
          { question_id: Q2, label: "1(b)", max: 6, a: 1, a_na: false, b: 6, b_na: false, tolerance: 1, out: true },
        ],
      }),
    );
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.review.second).toMatchObject({ markingId: "s1", rev: 2, markerName: "Bob Marker" });
    expect(r.review.compare.questions.map((q) => q.out)).toEqual([false, true]);
    expect(r.review.questions.filter((q) => q.leaf).map((q) => q.label)).toEqual(["1(a)", "1(b)"]);
    expect(r.review.first.annotations[0]).toEqual({ id: "a1", page_id: "p1", kind: "tick", x: 0.5, y: 0.5, question_id: Q1 });
    expect(JSON.stringify(r)).not.toContain("Jo");
  });
  it("without a second marking, the rows come from the first marks alone", () => {
    const r = parseReviewOpen(opened(null, null));
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.review.second).toBeNull();
    const rows = reviewRows(r.review.compare, r.review.final);
    expect(rows).toEqual([
      { label: "1(a)", max: 4, first: "3", second: "–", final: "–", out: false },
      { label: "1(b)", max: 6, first: "1", second: "–", final: "–", out: false },
    ]);
  });
  it("a refusal keeps its code", () => {
    expect(parseReviewOpen({ ok: false, code: "conflict_of_interest" })).toEqual({ ok: false, code: "conflict_of_interest" });
    expect(parseReviewOpen("nope")).toEqual({ ok: false, code: "internal" });
  });
});

describe("the page's own checks before the server is asked", () => {
  const questions = [
    { id: Q1, label: "1(a)", leaf: true, maxMark: 4, step: 1 as const },
    { id: Q2, label: "1(b)", leaf: true, maxMark: 6, step: 0.5 as const },
  ];
  it("every question needs a mark or NR, within its maximum and step", () => {
    expect(readMarks(questions, { [Q1]: { text: "3", na: false }, [Q2]: { text: "", na: true } })).toEqual({
      ok: true,
      marks: [
        { question_id: Q1, mark: 3, na: false },
        { question_id: Q2, mark: null, na: true },
      ],
    });
    expect(readMarks(questions, { [Q1]: { text: "3", na: false } })).toEqual({ ok: false, message: "Give every question a mark, or NR. Still to mark: 1(b)." });
    expect(readMarks(questions, { [Q1]: { text: "5", na: false }, [Q2]: { text: "1", na: false } })).toEqual({
      ok: false,
      message: "The mark for 1(a) must be from 0 to 4, in whole marks.",
    });
    expect(readMarks(questions, { [Q1]: { text: "1", na: false }, [Q2]: { text: "2.25", na: false } })).toEqual({
      ok: false,
      message: "The mark for 1(b) must be from 0 to 6, in half marks.",
    });
    expect(readMarks(questions, { [Q1]: { text: "1", na: false }, [Q2]: { text: "2.5", na: false } }).ok).toBe(true);
  });
  it("only the marks that change are sent as a final mark change", () => {
    const marks = [
      { question_id: Q1, mark: 3, na: false },
      { question_id: Q2, mark: null, na: true },
    ];
    expect(changedMarks(marks, [{ questionId: Q1, mark: 3, na: false }, { questionId: Q2, mark: 2, na: false }])).toEqual([{ question_id: Q2, mark: null, na: true }]);
    expect(changedMarks(marks, [{ questionId: Q1, mark: 3, na: false }, { questionId: Q2, mark: null, na: true }])).toEqual([]);
  });
  it("a note is 3 to 1,000 characters, and optional only where it may be left out", () => {
    expect(noteProblem("", false)).toBeNull();
    expect(noteProblem("  ", true)).toBe("Write a note of 3 to 1,000 characters.");
    expect(noteProblem("ok", false)).toBe("Write a note of 3 to 1,000 characters.");
    expect(noteProblem("x".repeat(1001), true)).toBe("Write a note of 3 to 1,000 characters.");
    expect(noteProblem(" Fine ", true)).toBeNull();
  });
});

describe("the markers and the practice and seeded scripts", () => {
  it("each marker's clearance in words", () => {
    const r = parseExamMarkers({
      ok: true,
      practice_on: true,
      seeds_on: true,
      markers: [
        { marker_id: "m1", name: "Lea Lead", lead: true, cleared: true, paused: false, misses: 0, practice: [], practice_left: 0, seeds: { done: 0, outside: 0 }, to_review: 0 },
        {
          marker_id: "m2",
          name: null,
          lead: false,
          cleared: false,
          paused: true,
          misses: 2,
          practice: [
            { standard_id: "s1", script_number: "P1-0001", total: 11, lead_total: 12, max_total: 20, within: true },
            { standard_id: "s2", script_number: "P1-0002", total: 4, lead_total: 12, max_total: 20, within: false },
          ],
          practice_left: 1,
          seeds: { done: 3, outside: 2 },
          to_review: 1,
        },
      ],
    });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(clearanceText(r.markers[0])).toBe("Cleared");
    expect(clearanceText(r.markers[1])).toBe("Practice: 2 of 3 done");
    expect(r.markers[1]).toMatchObject({ name: "Marker m2", paused: true, misses: 2 });
    expect(r.markers[1].practice[1]).toEqual({ standardId: "s2", scriptNumber: "P1-0002", total: 4, leadTotal: 12, maxTotal: 20, within: false });
  });
  it("the standards and the lead's own pieces that may become one", () => {
    const r = parseStandards({
      ok: true,
      standards: [
        { id: "st1", unit_id: "u1", use: "seed", script_number: "P1-0003", index_number: "SE-2026-0003", group_label: null, total: 12, max_total: 20, note: "Generous on 2.", retired: false, attempts: { done: 4, outside: 1 } },
      ],
      can_add: [{ unit_id: "u9", script_number: "P1-0009", index_number: "SE-2026-0009", group_label: "Section A", total: 15 }],
      more: false,
    });
    expect(r.ok).toBe(true);
    if (!r.ok) return;
    expect(r.standards[0]).toMatchObject({ id: "st1", use: "seed", note: "Generous on 2.", attempts: { done: 4, outside: 1 } });
    expect(r.canAdd).toEqual([{ unitId: "u9", scriptNumber: "P1-0009", indexNumber: "SE-2026-0009", groupLabel: "Section A", total: 15 }]);
    // An admin's list has no can_add.
    const a = parseStandards({ ok: true, standards: [] });
    expect(a.ok && a.canAdd).toBeNull();
  });
});
