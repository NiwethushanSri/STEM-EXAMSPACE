import { describe, expect, it } from "vitest";
import { keyAction } from "./marking-keys";
import {
  ACCESS_CHECK_MS,
  accessCheckDue,
  accessCheckOutcome,
  firstLeaf,
  labelList,
  markControls,
  markText,
  parseOpened,
  questionMarkText,
  questionPageIndexes,
  zoomStepIn,
  zoomStepOut,
} from "./marking-screen";

const U = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

const opened = {
  ok: true,
  unit: {
    id: U(1), exam_title: "Biology mock", paper: "Paper 1", subject: "Biology", script_number: "S-AB12-0001", index_number: "SE-2099-0001",
    group_label: null, deadline: null, hold_until: "2026-11-22T12:00:00Z", closed: false,
    first_name: "Wilhelmina",
  },
  marking: { id: U(2), rev: 4, status: "in_progress", lead_note: "See 2(b)", total: 3, max_total: 10, pages_changed: false },
  structure: {
    version: 1,
    questions: [
      { id: U(10), parent_id: null, label: "1", position: 1, max_mark: 3, mark_step: 1, levels: false, pages: [1], guidance: "Accept km/h", alternatives: null, option_group_id: null, points: [{ id: U(90), label: "M1", marks: 1, marks_to: null, text: "Method" }] },
      { id: U(11), parent_id: null, label: "2", position: 2, max_mark: null, mark_step: 1, levels: false, pages: [], option_group_id: null, points: [] },
      { id: U(12), parent_id: U(11), label: "a", position: 1, max_mark: 2, mark_step: 1, levels: false, pages: [2], option_group_id: null, points: [] },
      { id: U(13), parent_id: U(11), label: "b", position: 2, max_mark: 5, mark_step: 0.5, levels: true, pages: [3], option_group_id: null, points: [] },
      { id: U(14), parent_id: U(13), label: "i", position: 1, max_mark: 1, mark_step: 1, levels: false, pages: [3], option_group_id: null, points: [] },
    ],
    option_groups: [{ id: U(80), label: "Answer 1 of these", choose: 1 }],
    mark_scheme_file: { id: U(70), storage_path: `${U(60)}/${U(70)}.pdf` },
  },
  pages: [
    { n: 1, page_id: U(20), copy_page: 1, extra: false, marking_path: "e/u/1-1/0-marking.jpg", rotation: 0 },
    { n: 2, page_id: U(21), copy_page: 2, extra: false, marking_path: "e/u/1-1/1-marking.jpg", rotation: 0 },
    { n: 3, page_id: U(22), copy_page: null, extra: true, marking_path: null, rotation: 90 },
    { n: 4, page_id: U(23), copy_page: 3, extra: false, marking_path: "e/u/1-1/2-marking.jpg", rotation: 0 },
  ],
  marks: [{ question_id: U(10), mark: 3, na: false }, { question_id: U(12), mark: null, na: true }],
  annotations: [
    { id: U(30), page_id: U(20), kind: "tick", x: 0.5, y: 0.4, points: null, text: null, question_id: U(10) },
    { id: U(31), page_id: U(20), kind: "pen", x: 0.1, y: 0.1, points: [[0.1, 0.1], [0.2, 0.2]], text: null, question_id: null },
    { id: U(32), page_id: U(20), kind: "smiley", x: 0.1, y: 0.1 },
  ],
};

describe("parseOpened", () => {
  it("reads the piece and keeps only the fields it knows", () => {
    const r = parseOpened(opened);
    if (!r.ok) throw new Error("not ok");
    const p = r.piece;
    expect(p.unit).toEqual({
      id: U(1), examTitle: "Biology mock", paper: "Paper 1", scriptNumber: "S-AB12-0001", indexNumber: "SE-2099-0001",
      groupLabel: null, holdUntil: "2026-11-22T12:00:00Z", closed: false,
    });
    expect(JSON.stringify(p)).not.toContain("Wilhelmina");
    expect(p.marking).toEqual({ id: U(2), rev: 4, status: "in_progress", pagesChanged: false });
    expect(p.markSchemePath).toBe(`${U(60)}/${U(70)}.pdf`);
    expect(p.optionGroups).toEqual([{ id: U(80), label: "Answer 1 of these", choose: 1 }]);
    expect(p.pages.map((x) => [x.n, x.copyPage, x.extra, x.markingPath])).toEqual([
      [1, 1, false, "e/u/1-1/0-marking.jpg"],
      [2, 2, false, "e/u/1-1/1-marking.jpg"],
      [3, null, true, null],
      [4, 3, false, "e/u/1-1/2-marking.jpg"],
    ]);
  });

  it("labels questions as printed and knows which carry marks", () => {
    const r = parseOpened(opened);
    if (!r.ok) throw new Error("not ok");
    expect(r.piece.questions.map((q) => [q.label, q.depth, q.leaf, q.step])).toEqual([
      ["1", 0, true, 1],
      ["2", 0, false, 1],
      ["2(a)", 1, true, 1],
      ["2(b)", 1, false, 0.5],
      ["2(b)(i)", 2, true, 1],
    ]);
    expect(r.piece.questions[0].points).toEqual([{ id: U(90), label: "M1", marks: 1, marksTo: null, text: "Method" }]);
    expect(r.piece.questions[0].guidance).toBe("Accept km/h");
    expect(r.piece.questions[0].alternatives).toBe("");
  });

  it("keeps saved marks, the note and annotations of known kinds for the model", () => {
    const r = parseOpened(opened);
    if (!r.ok) throw new Error("not ok");
    expect(r.piece.saved.marking).toEqual({ lead_note: "See 2(b)" });
    expect(r.piece.saved.marks).toEqual([{ question_id: U(10), mark: 3, na: false }, { question_id: U(12), mark: null, na: true }]);
    expect(r.piece.saved.annotations?.map((a) => a.id)).toEqual([U(30), U(31)]);
    expect(r.piece.saved.annotations?.[1].points).toEqual([[0.1, 0.1], [0.2, 0.2]]);
  });

  it("returns the refusal code, or internal for an answer that makes no sense", () => {
    expect(parseOpened({ ok: false, code: "on_hold" })).toEqual({ ok: false, code: "on_hold" });
    expect(parseOpened({ ok: false })).toEqual({ ok: false, code: "internal" });
    expect(parseOpened(null)).toEqual({ ok: false, code: "internal" });
    expect(parseOpened({ ok: true, unit: {}, marking: {}, structure: {} })).toEqual({ ok: false, code: "internal" });
  });
});

describe("marks in plain words", () => {
  const r = parseOpened(opened);
  if (!r.ok) throw new Error("not ok");
  const qs = r.piece.questions;
  it("shows a mark, NR or a dash", () => {
    expect(markText(undefined)).toBe("–");
    expect(markText({ mark: null, na: false })).toBe("–");
    expect(markText({ mark: null, na: true })).toBe("NR");
    expect(markText({ mark: 2.5, na: false })).toBe("2.5");
    expect(markText({ mark: 0, na: false })).toBe("0");
  });
  it("adds up a question's parts once one has a mark", () => {
    expect(questionMarkText(qs[1], qs, {})).toBe("–");
    expect(questionMarkText(qs[1], qs, { [U(12)]: { mark: 2, na: false } })).toBe("2");
    expect(questionMarkText(qs[1], qs, { [U(12)]: { mark: 2, na: false }, [U(14)]: { mark: 1, na: false } })).toBe("3");
    expect(questionMarkText(qs[1], qs, { [U(12)]: { mark: null, na: true }, [U(14)]: { mark: null, na: true } })).toBe("NR");
    expect(questionMarkText(qs[1], qs, { [U(12)]: { mark: null, na: true } })).toBe("0");
  });
});

describe("pages of a question", () => {
  const r = parseOpened(opened);
  if (!r.ok) throw new Error("not ok");
  const { questions: qs, pages } = r.piece;
  it("finds the pages of a question and its parts; an extra page is no question's", () => {
    expect(questionPageIndexes(qs[0], qs, pages)).toEqual([0]);
    expect(questionPageIndexes(qs[1], qs, pages)).toEqual([1, 3]);
    expect(questionPageIndexes(qs[4], qs, pages)).toEqual([3]);
    expect(questionPageIndexes(undefined, qs, pages)).toEqual([]);
  });
  it("chooses the first part to mark of a question with parts", () => {
    expect(firstLeaf(qs[1], qs).label).toBe("2(a)");
    expect(firstLeaf(qs[3], qs).label).toBe("2(b)(i)");
    expect(firstLeaf(qs[0], qs).label).toBe("1");
  });
});

describe("zoom steps and lists", () => {
  it("zooms between 50% and 400%", () => {
    expect(zoomStepIn(1)).toBe(1.25);
    expect(zoomStepIn(1.1)).toBe(1.25);
    expect(zoomStepIn(4)).toBe(4);
    expect(zoomStepOut(1)).toBe(0.75);
    expect(zoomStepOut(0.5)).toBe(0.5);
    expect(zoomStepOut(3.3)).toBe(3);
  });
  it("names at most six questions", () => {
    expect(labelList(["1", "2"])).toBe("1, 2");
    expect(labelList(["1", "2", "3", "4", "5", "6", "7", "8"])).toBe("1, 2, 3, 4, 5, 6 and 2 more");
  });
});

describe("the minute check of a shown page", () => {
  const base = { visible: true, covered: false, path: "e/u/1-1/0-marking.jpg", lastAt: 0, now: ACCESS_CHECK_MS };
  it("withdrawn_page_check_runs_each_minute_while_in_view", () => {
    expect(ACCESS_CHECK_MS).toBe(60_000);
    expect(accessCheckDue(base)).toBe(true);
    expect(accessCheckDue({ ...base, now: ACCESS_CHECK_MS - 1 })).toBe(false);
    expect(accessCheckDue({ ...base, lastAt: 30_000, now: 90_000 })).toBe(true);
  });
  it("does not run while the tab is hidden, under a cover, or with no picture on the page", () => {
    expect(accessCheckDue({ ...base, visible: false })).toBe(false);
    expect(accessCheckDue({ ...base, covered: true })).toBe(false);
    expect(accessCheckDue({ ...base, path: null })).toBe(false);
  });
  it("a tab back in view checks at once when a minute has gone by", () => {
    expect(accessCheckDue({ ...base, lastAt: 10_000, now: 10 * 60_000 })).toBe(true);
    expect(accessCheckDue({ ...base, lastAt: 10 * 60_000 - 5_000, now: 10 * 60_000 })).toBe(false);
  });
  it("a refused link means the page is withdrawn; a failure to ask says nothing", () => {
    expect(accessCheckOutcome({ signed: true, status: null })).toBe("ok");
    expect(accessCheckOutcome({ signed: false, status: 400 })).toBe("gone");
    expect(accessCheckOutcome({ signed: false, status: 403 })).toBe("gone");
    expect(accessCheckOutcome({ signed: false, status: 404 })).toBe("gone");
    expect(accessCheckOutcome({ signed: false, status: 500 })).toBe("unknown");
    expect(accessCheckOutcome({ signed: false, status: null })).toBe("unknown");
  });
});

describe("markControls", () => {
  it("gives buttons up to 21 marks, and the number box whenever a digit key goes to it", () => {
    expect(markControls(5, 1)).toEqual({ buttons: [0, 1, 2, 3, 4, 5], box: false });
    expect(markControls(12, 1)).toEqual({ buttons: Array.from({ length: 13 }, (_, i) => i), box: true });
    expect(markControls(30, 1)).toEqual({ buttons: null, box: true });
    expect(markControls(10, 0.5).box).toBe(true);
  });
  it("shows the box for every maximum a digit key focuses it for, so no key is lost", () => {
    const digit = (max: number, step: 0.5 | 1) => keyAction({ key: "7", ctrl: false, meta: false, shift: false, alt: false, typing: false }, { max, step });
    for (const step of [0.5, 1] as const) {
      for (let max = step; max <= 100; max += step) {
        const c = markControls(max, step);
        expect(c.box || c.buttons !== null).toBe(true);
        if (digit(max, step)?.type === "focus_mark") expect(c.box, `out of ${max}`).toBe(true);
      }
    }
  });
});
