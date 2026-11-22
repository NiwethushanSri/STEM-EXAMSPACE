import { describe, expect, it } from "vitest";
import { markButtons, nextQuestionId, unitTotal, validMark } from "./marking-marks";

describe("marking marks", () => {
  it("valid_mark_respects_max_and_step", () => {
    expect(validMark(3, 4, 1)).toBe(true);
    expect(validMark(4.5, 4, 1)).toBe(false);
    expect(validMark(2.5, 4, 1)).toBe(false);
    expect(validMark(2.5, 4, 0.5)).toBe(true);
    expect(validMark(-1, 4, 1)).toBe(false);
    expect(validMark(0, 4, 1)).toBe(true);
    expect(validMark(Number.NaN, 4, 1)).toBe(false);
  });

  it("mark_buttons_fall_back_to_typing_over_21", () => {
    expect(markButtons(3, 1)).toEqual([0, 1, 2, 3]);
    expect(markButtons(2, 0.5)).toEqual([0, 0.5, 1, 1.5, 2]);
    expect(markButtons(20, 1)?.length).toBe(21);
    expect(markButtons(21, 1)).toBeNull();
    expect(markButtons(10, 0.5)?.length).toBe(21);
    expect(markButtons(10.5, 0.5)).toBeNull();
  });

  const questions = [
    { id: "q1", parent_id: null, label: "1", max_mark: null, option_group_id: null },
    { id: "q1a", parent_id: "q1", label: "a", max_mark: 2, option_group_id: null },
    { id: "q1b", parent_id: "q1", label: "b", max_mark: 3, option_group_id: null },
    { id: "q2", parent_id: null, label: "2", max_mark: 10, option_group_id: "g" },
    { id: "q3", parent_id: null, label: "3", max_mark: 8, option_group_id: "g" },
    { id: "q4", parent_id: null, label: "4", max_mark: 6, option_group_id: "g" },
  ];
  const groups = [{ id: "g", label: "Answer 2", choose: 2 }];

  it("unit_total_best_of_optional_and_missing_list", () => {
    const r = unitTotal(
      questions,
      { q1a: { mark: 2, na: false }, q1b: { mark: 1, na: false }, q2: { mark: 7, na: false }, q3: { mark: 3, na: false }, q4: { mark: 5, na: false } },
      groups,
      true,
    );
    expect(r.total).toBe(2 + 1 + 7 + 5);
    expect(r.max).toBe(5 + 10 + 8);
    expect(r.missing).toEqual([]);

    // 1(b) is blank; only one of the two optional questions is answered, so q3 and q4 are still to do.
    const m = unitTotal(questions, { q1a: { mark: 2, na: false }, q2: { mark: 4, na: false } }, groups, true);
    expect(m.total).toBe(6);
    expect(m.missing).toEqual(["q1b", "q3", "q4"]);

    // Two optional questions answered: the third may stay blank.
    const na = unitTotal(
      questions,
      { q1a: { mark: null, na: true }, q1b: { mark: 3, na: false }, q2: { mark: 1, na: false }, q3: { mark: 2, na: false } },
      groups,
      true,
    );
    expect(na.missing).toEqual([]);
    expect(na.total).toBe(3 + 1 + 2);
  });

  it("next question stops at the ends", () => {
    const l = [{ id: "a" }, { id: "b" }, { id: "c" }];
    expect(nextQuestionId(l, "a", 1)).toBe("b");
    expect(nextQuestionId(l, "c", 1)).toBe("c");
    expect(nextQuestionId(l, "a", -1)).toBe("a");
    expect(nextQuestionId(l, "c", -1)).toBe("b");
  });
});
