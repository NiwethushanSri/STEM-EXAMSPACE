import { describe, expect, it } from "vitest";
import {
  draftFromServer,
  maxTotal,
  parseLabel,
  toPayload,
  validateStructure,
  type DraftQuestion,
  type StructureDraft,
} from "./exam-structure";

const paper = { pageCount: 3, sparePages: 2 };

function q(key: string, label: string, maxMark: number | null, more: Partial<DraftQuestion> = {}): DraftQuestion {
  return {
    id: null,
    key,
    parentKey: null,
    label,
    maxMark,
    markStep: 1,
    levels: false,
    pages: [1],
    areas: [],
    groupKey: null,
    optionGroupKey: null,
    guidance: "",
    alternatives: "",
    points: [],
    ...more,
  };
}

/** 1 (3 marks) and 2 with parts (a) 2 and (b) 5. */
function base(): StructureDraft {
  return {
    groups: [],
    optionGroups: [],
    questions: [
      q("q1", "1", 3, { points: [{ label: "M1", marks: 1, marksTo: null, text: "speed = distance / time" }] }),
      q("q2", "2", null, { pages: [2, 3] }),
      q("q2a", "a", 2, { parentKey: "q2", pages: [2] }),
      q("q2b", "b", 5, { parentKey: "q2", pages: [3] }),
    ],
  };
}

describe("parse_label", () => {
  it("splits a full label into its levels", () => {
    expect(parseLabel("2(b)(i)")).toEqual(["2", "b", "i"]);
    expect(parseLabel("10")).toEqual(["10"]);
    expect(parseLabel(" 3 (a) ")).toEqual(["3", "a"]);
    expect(parseLabel("4(c)")).toEqual(["4", "c"]);
  });

  it("gives nothing for an empty label", () => {
    expect(parseLabel("")).toEqual([]);
    expect(parseLabel("  ")).toEqual([]);
  });
});

describe("validate_reports_each_bad_row", () => {
  it("accepts the test structure", () => {
    expect(validateStructure(base(), paper)).toEqual({ ok: true });
  });

  it("names every bad row with a message", () => {
    const d = base();
    d.questions[0] = { ...d.questions[0], maxMark: 2.5 };
    d.questions[2] = { ...d.questions[2], maxMark: null };
    d.questions[3] = { ...d.questions[3], pages: [6] };
    const res = validateStructure(d, paper);
    expect(res.ok).toBe(false);
    if (res.ok) return;
    expect(res.errors).toEqual([
      { key: "q1", message: "With whole marks, the maximum must be a whole number." },
      { key: "q2a", message: "Give this question a maximum mark." },
      { key: "q2b", message: "Page 6 is not a page of this paper." },
    ]);
  });

  it("refuses a maximum on a question with parts, labels used twice and a fourth level", () => {
    const d = base();
    d.questions[1] = { ...d.questions[1], maxMark: 7 };
    d.questions.push(q("q2b2", "b", null, { parentKey: "q2" }));
    d.questions.push(q("q2bi", "i", null, { parentKey: "q2b2" }));
    d.questions.push(q("q2bix", "x", 1, { parentKey: "q2bi" }));
    const res = validateStructure(d, paper);
    expect(res.ok).toBe(false);
    if (res.ok) return;
    expect(res.errors.map((e) => e.key)).toEqual(["q2", "q2b2", "q2bix"]);
    expect(res.errors[0].message).toBe("A question with parts has no maximum of its own.");
    expect(res.errors[1].message).toBe("Another part here is also labelled b.");
    expect(res.errors[2].message).toBe("Questions go at most 3 levels deep, as in 2(b)(i).");
  });

  it("checks marking points against the question's maximum", () => {
    const d = base();
    d.questions[0] = {
      ...d.questions[0],
      points: [
        { label: "M1", marks: 4, marksTo: null, text: "Too much" },
        { label: "L2", marks: 2, marksTo: 1, text: "Upside down" },
        { label: null, marks: 1, marksTo: null, text: "  " },
      ],
    };
    const res = validateStructure(d, paper);
    expect(res.ok).toBe(false);
    if (res.ok) return;
    expect(res.errors).toEqual([
      { key: "q1", message: "A marking point is worth at most the question's maximum." },
      { key: "q1", message: "The top of a band must be at least its bottom." },
      { key: "q1", message: "Each marking point needs its text." },
    ]);
  });

  it("checks optional questions and groups", () => {
    const d: StructureDraft = {
      groups: [
        { key: "g1", label: "Group 1" },
        { key: "g2", label: "Group 2" },
      ],
      optionGroups: [{ key: "o", label: "Section B", choose: 2 }],
      questions: [
        q("q5", "5", 10, { optionGroupKey: "o", groupKey: "g1" }),
        q("q6", "6", 8, { optionGroupKey: "o", groupKey: "g1" }),
        q("q7", "7", null, { groupKey: "g1" }),
        q("q7a", "a", 4, { parentKey: "q7", groupKey: "g1" }),
      ],
    };
    const res = validateStructure(d, paper);
    expect(res.ok).toBe(false);
    if (res.ok) return;
    expect(res.errors).toEqual([
      { key: "q7a", message: "Only whole questions go in a group." },
      { key: "g2", message: "Put at least one question in this group." },
      { key: "o", message: "Choose fewer than the number of questions." },
      { key: "o", message: "Optional questions must all be out of the same total." },
    ]);
  });

  it("needs at least one question to mark", () => {
    expect(validateStructure({ groups: [], optionGroups: [], questions: [] }, paper)).toEqual({
      ok: false,
      errors: [{ key: "structure", message: "Add at least one question." }],
    });
  });
});

describe("max_total_with_options", () => {
  it("adds the maxima of the questions to mark", () => {
    expect(maxTotal(base())).toBe(10);
  });

  it("counts only the best choose of the optional questions", () => {
    const d: StructureDraft = {
      groups: [],
      optionGroups: [{ key: "o", label: "Section B", choose: 2 }],
      questions: [
        q("q1", "1", 3),
        q("q5", "5", 10, { optionGroupKey: "o" }),
        q("q6", "6", 10, { optionGroupKey: "o" }),
        q("q7", "7", null, { optionGroupKey: "o" }),
        q("q7a", "a", 4, { parentKey: "q7" }),
        q("q7b", "b", 6, { parentKey: "q7" }),
      ],
    };
    expect(maxTotal(d)).toBe(23);
  });

  it("counts half marks exactly", () => {
    const d = base();
    d.questions[0] = { ...d.questions[0], maxMark: 2.5, markStep: 0.5 };
    expect(maxTotal(d)).toBe(9.5);
  });
});

describe("reading and sending a structure", () => {
  const server = {
    ok: true,
    version: 4,
    locked: false,
    max_total: 10.0,
    groups: [{ id: "g-1", label: "G1" }],
    option_groups: [],
    questions: [
      { id: "id-1", parent_id: null, label: "1", position: 1, max_mark: 3.0, mark_step: 1.0, levels: false, pages: [1], areas: [],
        group_id: "g-1", option_group_id: null, guidance: "Units needed.", alternatives: null,
        points: [{ id: "p-1", label: "M1", marks: 1.0, marks_to: null, text: "speed = distance / time" }] },
      { id: "id-2", parent_id: null, label: "2", position: 2, max_mark: null, mark_step: 1.0, levels: false, pages: [2, 3], areas: [],
        group_id: "g-1", option_group_id: null, guidance: null, alternatives: null, points: [] },
      { id: "id-3", parent_id: "id-2", label: "a", position: 1, max_mark: 7.0, mark_step: 0.5, levels: true, pages: [2], areas: [],
        group_id: null, option_group_id: null, guidance: null, alternatives: null, points: [] },
    ],
    mark_scheme_file: { id: "f-1", storage_path: "e/f-1.pdf" },
    paper: { page_count: 3, spare_pages: 2, answer_pages: [1, 2, 3] },
  };

  it("makes a draft keyed by id and sends it back in the database's shape", () => {
    const got = draftFromServer(server);
    expect(got).not.toBeNull();
    if (!got) return;
    expect(got.version).toBe(4);
    expect(got.markSchemeFile).toEqual({ id: "f-1", storagePath: "e/f-1.pdf" });
    expect(got.paper).toEqual({ pageCount: 3, sparePages: 2, answerPages: [1, 2, 3] });
    expect(got.draft.questions.map((x) => [x.key, x.parentKey, x.maxMark, x.markStep])).toEqual([
      ["id-1", null, 3, 1],
      ["id-2", null, null, 1],
      ["id-3", "id-2", 7, 0.5],
    ]);
    const payload = toPayload(got.draft);
    expect(payload.groups).toEqual([{ key: "g-1", label: "G1" }]);
    expect(payload.questions[0]).toEqual({
      id: "id-1", key: "id-1", parent_key: null, label: "1", max_mark: 3, mark_step: 1, levels: false, pages: [1], areas: [],
      group_key: "g-1", option_group_key: null, guidance: "Units needed.", alternatives: null,
      points: [{ label: "M1", marks: 1, marks_to: null, text: "speed = distance / time" }],
    });
    expect(payload.questions[1].guidance).toBeNull();
  });

  it("refuses an answer that is not a structure", () => {
    expect(draftFromServer({ ok: false, code: "forbidden" })).toBeNull();
    expect(draftFromServer(null)).toBeNull();
  });
});
