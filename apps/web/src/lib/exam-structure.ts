import { structureMessageFor } from "@stem/shared";

/**
 * An exam's questions and mark scheme as the editor holds them: a draft in paper order (each part straight after its
 * question and the earlier parts), the checks the editor shows before saving (the database checks every rule again,
 * and also which pages are answer pages), the paper total, and the conversions to and from the database's shape.
 */

export type MarkStep = 0.5 | 1;
export type DraftArea = { page: number; x: number; y: number; w: number; h: number };
/** A marking point; `marksTo` makes a level band from `marks` to `marksTo`. */
export type DraftPoint = { label: string | null; marks: number; marksTo: number | null; text: string };
export type DraftQuestion = {
  /** The saved question's id; null for a question not saved yet. */
  id: string | null;
  /** Names the question within the draft (its id once saved). */
  key: string;
  parentKey: string | null;
  label: string;
  /** Null for a question with parts. */
  maxMark: number | null;
  markStep: MarkStep;
  levels: boolean;
  pages: number[];
  areas: DraftArea[];
  /** Top-level questions only. */
  groupKey: string | null;
  optionGroupKey: string | null;
  guidance: string;
  alternatives: string;
  points: DraftPoint[];
};
export type DraftGroup = { key: string; label: string };
export type DraftOptionGroup = { key: string; label: string; choose: number };
export type StructureDraft = { groups: DraftGroup[]; optionGroups: DraftOptionGroup[]; questions: DraftQuestion[] };
export type StructureError = { key: string; message: string };

export const MAX_QUESTIONS = 200;
export const MAX_DEPTH = 3;
export const MAX_POINTS = 30;
export const MAX_AREAS = 5;
export const MIN_MARK = 0.5;
export const MAX_MARK = 100;
export const LABEL_MAX = 20;
export const GROUP_LABEL_MAX = 40;
export const OPTION_LABEL_MAX = 60;
export const POINT_LABEL_MAX = 12;
export const POINT_TEXT_MAX = 500;
export const GUIDANCE_MAX = 4000;
export const ALTERNATIVES_MAX = 2000;
/** The mark scheme PDF is at most 20 MB (the bucket and mark_scheme_file_begin say the same). */
export const MARK_SCHEME_MAX_BYTES = 20 * 1024 * 1024;

/** The levels of a full label: "2(b)(i)" is ["2", "b", "i"]. */
export function parseLabel(text: string): string[] {
  return text.split(/[()\s]+/).filter(Boolean);
}

const childrenOf = (d: StructureDraft, key: string) => d.questions.filter((q) => q.parentKey === key);
const hasParts = (d: StructureDraft, key: string) => d.questions.some((q) => q.parentKey === key);
const byKey = (d: StructureDraft, key: string | null) => (key === null ? undefined : d.questions.find((q) => q.key === key));

/** How deep a question sits: 1 for a question, 2 for a part, 3 for a part of a part (0 when its chain is broken). */
export function depthOf(d: StructureDraft, key: string): number {
  let n = 0;
  let q = byKey(d, key);
  const seen = new Set<string>();
  while (q) {
    if (seen.has(q.key)) return 0;
    seen.add(q.key);
    n += 1;
    if (q.parentKey === null) return n;
    q = byKey(d, q.parentKey);
  }
  return 0;
}

/** The label as printed on the paper: "2(b)(i)". */
export function fullLabel(d: StructureDraft, key: string): string {
  const chain: string[] = [];
  let q = byKey(d, key);
  while (q && chain.length <= MAX_DEPTH) {
    chain.unshift(q.label.trim());
    q = byKey(d, q.parentKey);
  }
  return chain[0] + chain.slice(1).map((l) => `(${l})`).join("");
}

/** A question's total: its maximum, or the sum of its parts. */
export function totalOf(d: StructureDraft, key: string, depth = 0): number {
  const q = byKey(d, key);
  if (!q || depth > MAX_DEPTH) return 0;
  const parts = childrenOf(d, key);
  if (parts.length === 0) return q.maxMark ?? 0;
  return parts.reduce((sum, p) => sum + totalOf(d, p.key, depth + 1), 0);
}

/** The paper total: every question to mark, counting only the best `choose` of each set of optional questions. */
export function maxTotal(d: StructureDraft): number {
  const options = new Map(d.optionGroups.map((o) => [o.key, { choose: o.choose, totals: [] as number[] }]));
  let sum = 0;
  for (const q of d.questions) {
    if (q.parentKey !== null) continue;
    const total = totalOf(d, q.key);
    const option = q.optionGroupKey ? options.get(q.optionGroupKey) : undefined;
    if (option) option.totals.push(total);
    else sum += total;
  }
  for (const o of options.values()) {
    sum += o.totals.sort((a, b) => b - a).slice(0, Math.max(0, o.choose)).reduce((a, b) => a + b, 0);
  }
  return sum;
}

const isMultiple = (x: number, step: number) => Math.abs(x / step - Math.round(x / step)) < 1e-9;

/**
 * The editor's checks, row by row in paper order, then the groups, then the optional questions. Pages are checked
 * against the paper's pages and spare pages; the database also refuses pages that are not answer pages.
 */
export function validateStructure(
  d: StructureDraft,
  paper: { pageCount: number; sparePages: number },
): { ok: true } | { ok: false; errors: StructureError[] } {
  const errors: StructureError[] = [];
  const add = (key: string, message: string) => errors.push({ key, message });
  const lastPage = paper.pageCount + paper.sparePages;
  const leaves = d.questions.filter((q) => !hasParts(d, q.key));

  if (d.questions.length === 0) add("structure", "Add at least one question.");
  else if (leaves.length > MAX_QUESTIONS) add("structure", `An exam can have at most ${MAX_QUESTIONS} questions to mark.`);

  d.questions.forEach((q, i) => {
    const label = q.label.trim();
    const parts = hasParts(d, q.key);
    const depth = depthOf(d, q.key);
    if (!label) add(q.key, "Give this question a label.");
    else if (label.length > LABEL_MAX) add(q.key, `A label can be at most ${LABEL_MAX} characters.`);
    else if (d.questions.slice(0, i).some((o) => o.parentKey === q.parentKey && o.label.trim() === label)) {
      add(q.key, q.parentKey === null ? `Another question is also labelled ${label}.` : `Another part here is also labelled ${label}.`);
    }
    if (depth === 0) add(q.key, "This part's question is missing.");
    else if (depth > MAX_DEPTH) add(q.key, "Questions go at most 3 levels deep, as in 2(b)(i).");

    if (parts) {
      if (q.maxMark !== null) add(q.key, "A question with parts has no maximum of its own.");
    } else if (q.maxMark === null || !Number.isFinite(q.maxMark)) {
      add(q.key, "Give this question a maximum mark.");
    } else if (q.maxMark < MIN_MARK || q.maxMark > MAX_MARK) {
      add(q.key, `A maximum mark is between ${MIN_MARK} and ${MAX_MARK}.`);
    } else if (!isMultiple(q.maxMark, q.markStep)) {
      add(q.key, q.markStep === 1 ? "With whole marks, the maximum must be a whole number." : "The maximum must be a whole or half mark.");
    }

    const badPage = q.pages.find((p) => !Number.isInteger(p) || p < 1 || p > lastPage);
    if (badPage !== undefined) add(q.key, `Page ${badPage} is not a page of this paper.`);
    if (q.areas.length > MAX_AREAS) add(q.key, `A question can have at most ${MAX_AREAS} areas.`);

    if (q.parentKey !== null && q.groupKey !== null) add(q.key, "Only whole questions go in a group.");
    if (q.parentKey !== null && q.optionGroupKey !== null) add(q.key, "Only whole questions can be optional.");

    if (q.points.length > MAX_POINTS) add(q.key, `A question can have at most ${MAX_POINTS} marking points.`);
    const total = totalOf(d, q.key);
    for (const p of q.points) {
      if ((p.label ?? "").trim().length > POINT_LABEL_MAX) add(q.key, `A marking point's label can be at most ${POINT_LABEL_MAX} characters.`);
      if (!Number.isFinite(p.marks) || p.marks < 0 || !isMultiple(p.marks, 0.5)) add(q.key, "A marking point is worth a whole or half mark.");
      else if (p.marks > total || (p.marksTo !== null && p.marksTo > total)) add(q.key, "A marking point is worth at most the question's maximum.");
      else if (p.marksTo !== null && (!isMultiple(p.marksTo, 0.5) || p.marksTo < p.marks)) add(q.key, "The top of a band must be at least its bottom.");
      if (!p.text.trim()) add(q.key, "Each marking point needs its text.");
      else if (p.text.trim().length > POINT_TEXT_MAX) add(q.key, `A marking point can be at most ${POINT_TEXT_MAX} characters.`);
    }
    if (q.guidance.trim().length > GUIDANCE_MAX) add(q.key, `Guidance can be at most ${GUIDANCE_MAX} characters.`);
    if (q.alternatives.trim().length > ALTERNATIVES_MAX) add(q.key, `Acceptable alternatives can be at most ${ALTERNATIVES_MAX} characters.`);
  });

  d.groups.forEach((g, i) => {
    const label = g.label.trim();
    if (!label) add(g.key, "Give this group a name.");
    else if (label.length > GROUP_LABEL_MAX) add(g.key, `A group's name can be at most ${GROUP_LABEL_MAX} characters.`);
    else if (d.groups.slice(0, i).some((o) => o.label.trim() === label)) add(g.key, `Another group is also called ${label}.`);
    if (!d.questions.some((q) => q.groupKey === g.key)) add(g.key, "Put at least one question in this group.");
  });

  d.optionGroups.forEach((o, i) => {
    const label = o.label.trim();
    if (!label) add(o.key, "Give these optional questions a name.");
    else if (label.length > OPTION_LABEL_MAX) add(o.key, `The name can be at most ${OPTION_LABEL_MAX} characters.`);
    else if (d.optionGroups.slice(0, i).some((x) => x.label.trim() === label)) add(o.key, `Other optional questions are also called ${label}.`);
    const members = d.questions.filter((q) => q.optionGroupKey === o.key);
    if (members.length < 2) add(o.key, "Optional questions need at least 2 questions.");
    else if (!Number.isInteger(o.choose) || o.choose < 1) add(o.key, "Choose a whole number of at least 1.");
    else if (o.choose >= members.length) add(o.key, "Choose fewer than the number of questions.");
    if (new Set(members.map((q) => totalOf(d, q.key))).size > 1) add(o.key, "Optional questions must all be out of the same total.");
  });

  return errors.length === 0 ? { ok: true } : { ok: false, errors };
}

// ---------------------------------------------------------------------------------------------
// Editing the draft. Every change keeps paper order.
// ---------------------------------------------------------------------------------------------

let seq = 0;
/** A key for a row not saved yet (never an id). */
export const newKey = (prefix = "new") => `${prefix}-${++seq}`;

/** The questions in paper order: each question's parts in their current order straight after it. */
function inPaperOrder(questions: DraftQuestion[]): DraftQuestion[] {
  const out: DraftQuestion[] = [];
  const visit = (parent: string | null, depth: number) => {
    if (depth > MAX_DEPTH + 1) return;
    for (const q of questions) {
      if (q.parentKey !== parent) continue;
      out.push(q);
      visit(q.key, depth + 1);
    }
  };
  visit(null, 1);
  return out;
}

const ROMAN = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii"];

/** The label the next part (or question) is given: 3, then (a), (b), then (i), (ii). */
function nextLabel(d: StructureDraft, parentKey: string | null): string {
  const siblings = d.questions.filter((q) => q.parentKey === parentKey);
  if (parentKey === null) {
    const numbers = siblings.map((q) => Number.parseInt(q.label, 10)).filter(Number.isFinite);
    return String(numbers.length ? Math.max(...numbers) + 1 : 1);
  }
  const n = siblings.length;
  return depthOf(d, parentKey) === 1 ? String.fromCharCode(97 + (n % 26)) : (ROMAN[n] ?? String(n + 1));
}

function blank(key: string, parentKey: string | null, label: string, pages: number[]): DraftQuestion {
  return {
    id: null, key, parentKey, label, maxMark: null, markStep: 1, levels: false, pages, areas: [], groupKey: null,
    optionGroupKey: null, guidance: "", alternatives: "", points: [],
  };
}

/** A new question at the end. */
export function addQuestion(d: StructureDraft): StructureDraft {
  return { ...d, questions: [...d.questions, blank(newKey(), null, nextLabel(d, null), [])] };
}

/** A new part under a question, after its other parts. A question getting its first part hands it its maximum. */
export function addPart(d: StructureDraft, parentKey: string): StructureDraft {
  const parent = byKey(d, parentKey);
  if (!parent) return d;
  const first = !hasParts(d, parentKey);
  const part = { ...blank(newKey(), parentKey, nextLabel(d, parentKey), [...parent.pages]), markStep: parent.markStep, maxMark: first ? parent.maxMark : null };
  const questions = d.questions.map((q) => (q.key === parentKey ? { ...q, maxMark: null } : q));
  return { ...d, questions: inPaperOrder([...questions, part]) };
}

/** Removes a question with its parts. */
export function removeQuestion(d: StructureDraft, key: string): StructureDraft {
  const gone = new Set([key]);
  for (let grew = true; grew; ) {
    grew = false;
    for (const q of d.questions) {
      if (q.parentKey !== null && gone.has(q.parentKey) && !gone.has(q.key)) {
        gone.add(q.key);
        grew = true;
      }
    }
  }
  return { ...d, questions: d.questions.filter((q) => !gone.has(q.key)) };
}

/** Moves a question (with its parts) one place up (-1) or down (+1) among its siblings. */
export function moveQuestion(d: StructureDraft, key: string, by: -1 | 1): StructureDraft {
  const q = byKey(d, key);
  if (!q) return d;
  const siblings = d.questions.filter((x) => x.parentKey === q.parentKey);
  const i = siblings.findIndex((x) => x.key === key);
  const j = i + by;
  if (j < 0 || j >= siblings.length) return d;
  const order = [...d.questions];
  const a = order.findIndex((x) => x.key === siblings[i].key);
  const b = order.findIndex((x) => x.key === siblings[j].key);
  [order[a], order[b]] = [order[b], order[a]];
  return { ...d, questions: inPaperOrder(order) };
}

/** Changes one question. */
export function updateQuestion(d: StructureDraft, key: string, change: Partial<DraftQuestion>): StructureDraft {
  return { ...d, questions: d.questions.map((q) => (q.key === key ? { ...q, ...change } : q)) };
}

/** Whether the question has parts. */
export function isParent(d: StructureDraft, key: string): boolean {
  return hasParts(d, key);
}

// ---------------------------------------------------------------------------------------------
// The database's shape.
// ---------------------------------------------------------------------------------------------

export type StructurePaper = { pageCount: number; sparePages: number; answerPages: number[] };
export type StructureView = {
  draft: StructureDraft;
  version: number;
  locked: boolean;
  maxTotal: number;
  markSchemeFile: { id: string; storagePath: string } | null;
  /** Null while the exam has no paper. */
  paper: StructurePaper | null;
};

const obj = (v: unknown): Record<string, unknown> | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null);
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const nums = (v: unknown): number[] => arr(v).filter((n): n is number => typeof n === "number");

/** exam_structure_get's answer as an editor's draft (the keys are the ids); null when it is not a structure. */
export function draftFromServer(raw: unknown): StructureView | null {
  const r = obj(raw);
  if (!r || r.ok !== true || !Array.isArray(r.questions)) return null;
  const groups = arr(r.groups).flatMap((g) => {
    const o = obj(g);
    const id = str(o?.id);
    return id ? [{ key: id, label: str(o?.label) ?? "" }] : [];
  });
  const optionGroups = arr(r.option_groups).flatMap((g) => {
    const o = obj(g);
    const id = str(o?.id);
    return id ? [{ key: id, label: str(o?.label) ?? "", choose: num(o?.choose) ?? 1 }] : [];
  });
  const questions = arr(r.questions).flatMap((x): DraftQuestion[] => {
    const q = obj(x);
    const id = str(q?.id);
    if (!q || !id) return [];
    return [{
      id,
      key: id,
      parentKey: str(q.parent_id),
      label: str(q.label) ?? "",
      maxMark: num(q.max_mark),
      markStep: num(q.mark_step) === 0.5 ? 0.5 : 1,
      levels: q.levels === true,
      pages: nums(q.pages),
      areas: arr(q.areas).flatMap((a) => {
        const o = obj(a);
        const [page, x0, y, w, h] = [num(o?.page), num(o?.x), num(o?.y), num(o?.w), num(o?.h)];
        return page !== null && x0 !== null && y !== null && w !== null && h !== null ? [{ page, x: x0, y, w, h }] : [];
      }),
      groupKey: str(q.group_id),
      optionGroupKey: str(q.option_group_id),
      guidance: str(q.guidance) ?? "",
      alternatives: str(q.alternatives) ?? "",
      points: arr(q.points).flatMap((p) => {
        const o = obj(p);
        const marks = num(o?.marks);
        return o && marks !== null ? [{ label: str(o.label), marks, marksTo: num(o.marks_to), text: str(o.text) ?? "" }] : [];
      }),
    }];
  });
  const file = obj(r.mark_scheme_file);
  const paper = obj(r.paper);
  return {
    draft: { groups, optionGroups, questions },
    version: num(r.version) ?? 0,
    locked: r.locked === true,
    maxTotal: num(r.max_total) ?? 0,
    markSchemeFile: file && str(file.id) && str(file.storage_path) ? { id: str(file.id)!, storagePath: str(file.storage_path)! } : null,
    paper: paper
      ? { pageCount: num(paper.page_count) ?? 0, sparePages: num(paper.spare_pages) ?? 0, answerPages: nums(paper.answer_pages) }
      : null,
  };
}

export type StructurePayload = {
  groups: { key: string; label: string }[];
  option_groups: { key: string; label: string; choose: number }[];
  questions: {
    id: string | null;
    key: string;
    parent_key: string | null;
    label: string;
    max_mark: number | null;
    mark_step: number;
    levels: boolean;
    pages: number[];
    areas: DraftArea[];
    group_key: string | null;
    option_group_key: string | null;
    guidance: string | null;
    alternatives: string | null;
    points: { label: string | null; marks: number; marks_to: number | null; text: string }[];
  }[];
};

/** The draft in exam_structure_save's shape (p_structure). */
export function toPayload(d: StructureDraft): StructurePayload {
  const blankToNull = (s: string) => (s.trim() ? s.trim() : null);
  return {
    groups: d.groups.map((g) => ({ key: g.key, label: g.label.trim() })),
    option_groups: d.optionGroups.map((o) => ({ key: o.key, label: o.label.trim(), choose: o.choose })),
    questions: inPaperOrder(d.questions).map((q) => ({
      id: q.id,
      key: q.key,
      parent_key: q.parentKey,
      label: q.label.trim(),
      max_mark: q.maxMark,
      mark_step: q.markStep,
      levels: q.levels,
      pages: q.pages,
      areas: q.areas,
      group_key: q.parentKey === null ? q.groupKey : null,
      option_group_key: q.parentKey === null ? q.optionGroupKey : null,
      guidance: blankToNull(q.guidance),
      alternatives: blankToNull(q.alternatives),
      points: q.points.map((p) => ({ label: p.label?.trim() ? p.label.trim() : null, marks: p.marks, marks_to: p.marksTo, text: p.text.trim() })),
    })),
  };
}

/** What a structure or PDF action answers. A saved structure comes back as the editor's new draft. */
export type StructureResult = { ok: true; message: string; view?: StructureView } | { ok: false; message: string };

/** A begun mark scheme PDF upload: the file row and the path the browser sends the file to. */
export type FileBegun = { ok: true; fileId: string; path: string } | { ok: false; code: string };

/** An RPC answer's failure message; null when it succeeded. */
export function structureFailure(data: unknown, error: unknown, context: "save" | "file"): string | null {
  const r = obj(data);
  if (error || !r) return structureMessageFor("internal", context);
  if (r.ok === true) return null;
  return structureMessageFor(str(r.code), context);
}

/** "60 marks", "1 mark", "12.5 marks". */
export function marksText(n: number): string {
  return `${n} ${n === 1 ? "mark" : "marks"}`;
}
