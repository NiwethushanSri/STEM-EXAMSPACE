import { describe, expect, it } from "vitest";
import { act, applyOps, erasedBy, fromServer, inverse, redo, rulerCm, undo, type SavedAnnotation } from "./marking-model";

const tick = (id: string, x = 0.5, y = 0.5, page = "p1"): SavedAnnotation => ({ id, page_id: page, kind: "tick", x, y });
const empty = () => fromServer({ marking: { lead_note: null }, marks: [], annotations: [] });

describe("marking model", () => {
  it("apply_mark_and_annotation_ops", () => {
    let s = fromServer({
      marking: { lead_note: "hello" },
      marks: [{ question_id: "q1", mark: 2, na: false }],
      annotations: [{ ...tick("a1"), points: null, text: null, question_id: null }],
    });
    expect(s.note).toBe("hello");
    expect(s.marks.q1).toEqual({ mark: 2, na: false });
    expect(s.annotations[0]).toEqual(tick("a1"));
    s = applyOps(s, [
      { op: "mark", question_id: "q2", mark: null, na: true },
      { op: "ann_put", ...tick("a2") },
      { op: "ann_del", id: "a1" },
      { op: "note", text: "n" },
    ]);
    expect(s.marks.q2).toEqual({ mark: null, na: true });
    expect(s.annotations.map((a) => a.id)).toEqual(["a2"]);
    expect(s.deleted.map((a) => a.id)).toEqual(["a1"]);
    expect(s.note).toBe("n");
    s = applyOps(s, [{ op: "ann_restore", id: "a1" }]);
    expect(s.annotations.map((a) => a.id).sort()).toEqual(["a1", "a2"]);
    expect(s.deleted).toEqual([]);
  });

  it("undo_then_redo_restores_and_emits_inverse_ops", () => {
    let s = empty();
    let r = act(s, [{ op: "ann_put", ...tick("a1") }]);
    expect(r.send).toEqual([{ op: "ann_put", ...tick("a1") }]);
    s = r.state;
    r = act(s, [{ op: "mark", question_id: "q1", mark: 1, na: false }]);
    s = r.state;
    r = act(s, [{ op: "mark", question_id: "q1", mark: 3, na: false }]);
    s = r.state;
    expect(s.redo).toEqual([]);

    let u = undo(s);
    expect(u.send).toEqual([{ op: "mark", question_id: "q1", mark: 1, na: false }]);
    expect(u.state.marks.q1.mark).toBe(1);
    const rd = redo(u.state);
    expect(rd.send).toEqual([{ op: "mark", question_id: "q1", mark: 3, na: false }]);
    expect(rd.state.marks.q1.mark).toBe(3);

    u = undo(undo(undo(s).state).state);
    expect(u.send).toEqual([{ op: "ann_del", id: "a1" }]);
    expect(u.state.annotations).toEqual([]);
    expect(redo(u.state).send).toEqual([{ op: "ann_restore", id: "a1" }]);
    expect(undo(u.state).send).toEqual([]);
  });

  it("act clears redo and undo reverses a multi-op action in reverse order", () => {
    let s = empty();
    s = act(s, [{ op: "mark", question_id: "q1", mark: 1, na: false }]).state;
    s = undo(s).state;
    expect(s.redo.length).toBe(1);
    const r = act(s, [
      { op: "mark", question_id: "q1", mark: 2, na: false },
      { op: "mark", question_id: "q1", mark: 4, na: false },
    ]);
    expect(r.state.redo).toEqual([]);
    const u = undo(r.state);
    expect(u.send).toEqual([
      { op: "mark", question_id: "q1", mark: 2, na: false },
      { op: "mark", question_id: "q1", mark: null, na: false },
    ]);
    expect(u.state.marks.q1).toEqual({ mark: null, na: false });
  });

  it("inverse of a deletion restores, and of a moved annotation puts the old one back", () => {
    const s = applyOps(empty(), [{ op: "ann_put", ...tick("a1", 0.1, 0.1) }]);
    expect(inverse(s, { op: "ann_del", id: "a1" })).toEqual({ op: "ann_restore", id: "a1" });
    expect(inverse(s, { op: "ann_put", ...tick("a1", 0.9, 0.9) })).toEqual({ op: "ann_put", ...tick("a1", 0.1, 0.1) });
    expect(inverse(s, { op: "note", text: "x" })).toEqual({ op: "note", text: "" });
  });

  it("erased_by_hits_only_this_pages_marks", () => {
    const anns: SavedAnnotation[] = [
      tick("near", 0.5, 0.5),
      tick("other_page", 0.5, 0.5, "p2"),
      tick("far", 0.9, 0.9),
      { id: "line", page_id: "p1", kind: "pen", x: 0.1, y: 0.2, points: [[0.1, 0.2], [0.3, 0.2]] },
    ];
    expect(erasedBy([[0.505, 0.5]], anns, "p1")).toEqual(["near"]);
    expect(erasedBy([[0.2, 0.205]], anns, "p1")).toEqual(["line"]);
    expect(erasedBy([[0.5, 0.5], [0.52, 0.5]], anns, "p1", 0.001)).toEqual(["near"]);
    expect(erasedBy([[0.5, 0.5]], anns, "p3")).toEqual([]);
  });

  it("ruler_cm_on_a4", () => {
    expect(rulerCm([[0, 0.5], [1, 0.5]])).toBe(21);
    expect(rulerCm([[0.5, 0], [0.5, 1]])).toBe(29.7);
    expect(rulerCm([[0.5, 0.5]])).toBe(0);
  });
});
