/** The lead marker's review (/marking/review) and the admin's check columns (/admin/marking): what they read from
 * marking_review_list, marking_review_open, marking_exam_markers and marking_standards_list, the check of a piece in
 * plain words, the review table's rows, and the checks the page makes before it asks the server (a mark per question
 * within its maximum and step, a note of 3 to 1,000 characters). Each parser keeps only the fields it knows, so nothing
 * else reaches a page: the functions give the script number, the index number and the markers' names, never a
 * candidate's name. The database checks every rule again. */
import { reviewMessageFor } from "@stem/shared";
import { markText } from "@/lib/marking-feedback";
import { validMark } from "@/lib/marking-marks";
import type { SavedAnnotation } from "@/lib/marking-model";
import { labelList, parseAnnotations, parseQuestions, type ScreenQuestion } from "@/lib/marking-screen";

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const list = (v: unknown): Obj[] => (Array.isArray(v) ? v.map(obj).filter((x): x is Obj => x !== null) : []);
const str = (v: unknown): string | null => (typeof v === "string" ? v : typeof v === "number" ? String(v) : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const count = (v: unknown): number => (typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : 0);
const time = (v: unknown): string | null => (typeof v === "string" && !Number.isNaN(Date.parse(v)) ? v : null);
const refusal = (d: Obj | null): { ok: false; code: string } => ({ ok: false, code: typeof d?.code === "string" ? d.code : "internal" });

export const REVIEW_KINDS = ["difference", "paused_marker", "sample"] as const;
export type ReviewKind = (typeof REVIEW_KINDS)[number];
const isKind = (v: unknown): v is ReviewKind => REVIEW_KINDS.includes(v as ReviewKind);

/** A piece's check (marking_units.check_state) in words; for a piece with the lead marker, what it waits for when the
 * kind of its review is known. "" for none (not submitted yet, or a state this page does not know). */
export function checkStateText(state: string | null, kind?: string): string {
  if (state === "waiting_second") return "Waiting for a second marker";
  if (state === "checked") return "Checked";
  if (state !== "to_lead") return "";
  if (kind === "difference") return "With the lead marker: marks differ";
  if (kind === "paused_marker") return "With the lead marker: marker paused";
  return "With the lead marker";
}

/** The admin list's second pass of a piece (marking_units_list's second) in words: who has it and where it stands. */
export function secondMarkerText(second: { markerName: string; state: string } | null): string {
  if (!second) return "";
  const where = second.state === "taken" ? "being marked" : second.state === "submitted" ? "submitted" : "in progress";
  return `${second.markerName} (${where})`;
}

/** Above the review's tabs, when pieces wait for a second marker whom nobody can be (Review Focus 2). */
export function stuckText(n: number): string {
  if (n === 1) {
    return "1 script waits for a second marker and nobody can take it. Assign one on the Marking page, or release it with a reason.";
  }
  return `${n} scripts wait for a second marker and nobody can take them. Assign one on the Marking page, or release them with a reason.`;
}

/** What a review row says when the caller is one of its two markers. */
export const PARTY_TEXT = "You marked this script.";

export type ReviewMarker = { markerId: string; name: string; total: number | null };
export type ReviewItem = {
  reviewId: string;
  kind: ReviewKind;
  examId: string;
  examTitle: string;
  unitId: string;
  scriptNumber: string;
  indexNumber: string | null;
  groupLabel: string | null;
  first: ReviewMarker;
  second: ReviewMarker | null;
  maxTotal: number | null;
  openedAt: string | null;
  party: boolean;
};
export type ReviewCounts = { difference: number; pausedMarker: number; sample: number; toClear: number; stuckSecond: number };
export type ReviewList = { counts: ReviewCounts; items: ReviewItem[]; more: boolean };

function markerOf(v: unknown): ReviewMarker | null {
  const m = obj(v);
  const markerId = str(m?.marker_id);
  return m && markerId ? { markerId, name: str(m.name) ?? "Marker", total: num(m.total) } : null;
}

/** marking_review_list's answer (an item of a kind it does not know is left out), or the code it was refused with. */
export function parseReviewList(data: unknown): { ok: true; list: ReviewList } | { ok: false; code: string } {
  const d = obj(data);
  if (d?.ok !== true) return refusal(d);
  const c = obj(d.counts) ?? {};
  const items: ReviewItem[] = [];
  for (const i of list(d.items)) {
    const reviewId = str(i.review_id);
    const examId = str(i.exam_id);
    const unitId = str(i.unit_id);
    const first = markerOf(i.first);
    if (!reviewId || !examId || !unitId || !first || !isKind(i.kind)) continue;
    items.push({
      reviewId,
      kind: i.kind,
      examId,
      examTitle: str(i.exam_title) ?? "",
      unitId,
      scriptNumber: str(i.script_number) ?? "",
      indexNumber: str(i.index_number),
      groupLabel: str(i.group_label),
      first,
      second: markerOf(i.second),
      maxTotal: num(i.max_total),
      openedAt: time(i.opened_at),
      party: i.party === true,
    });
  }
  return {
    ok: true,
    list: {
      counts: {
        difference: count(c.difference),
        pausedMarker: count(c.paused_marker),
        sample: count(c.sample),
        toClear: count(c.to_clear),
        stuckSecond: count(c.stuck_second),
      },
      items,
      more: d.more === true,
    },
  };
}

export type ReviewMark = { questionId: string; mark: number | null; na: boolean };
export type ReviewMarking = {
  markingId: string;
  rev: number;
  markerName: string;
  total: number | null;
  /** The marker's private note to the lead marker. */
  leadNote: string | null;
  submittedAt: string | null;
  marks: ReviewMark[];
  annotations: SavedAnnotation[];
};
export type CompareQuestion = { questionId: string; label: string; max: number | null; a: number | null; aNa: boolean; b: number | null; bNa: boolean; out: boolean };
/** The two markings side by side (marking_compare_sets: a is the first, b the second); with no second marking, the
 * first marks alone (b empty, nothing out). */
export type ReviewCompare = { within: boolean; totalA: number | null; totalB: number | null; maxTotal: number | null; questions: CompareQuestion[] };
export type FinalMark = { questionId: string; mark: number | null; na: boolean; source: string | null };
export type ReviewQuestion = Pick<ScreenQuestion, "id" | "parentId" | "label" | "leaf" | "maxMark" | "step" | "optionGroupId">;
export type OpenedReview = {
  review: { id: string; kind: ReviewKind; open: boolean; outcome: string | null; party: boolean };
  unit: { id: string; examTitle: string; paper: string; scriptNumber: string; indexNumber: string | null; groupLabel: string | null };
  questions: ReviewQuestion[];
  optionGroups: { id: string; label: string; choose: number }[];
  pages: { n: number; page_id: string }[];
  first: ReviewMarking;
  second: ReviewMarking | null;
  compare: ReviewCompare;
  final: FinalMark[];
};

function markingOf(v: unknown): ReviewMarking | null {
  const m = obj(v);
  const markingId = str(m?.marking_id);
  const rev = num(m?.rev);
  if (!m || !markingId || rev === null) return null;
  return {
    markingId,
    rev,
    markerName: str(m.marker_name) ?? "Marker",
    total: num(m.total),
    leadNote: str(m.lead_note),
    submittedAt: time(m.submitted_at),
    marks: list(m.marks).flatMap((x) => {
      const questionId = str(x.question_id);
      return questionId ? [{ questionId, mark: num(x.mark), na: x.na === true }] : [];
    }),
    annotations: parseAnnotations(m.annotations).map((a) => {
      const out: SavedAnnotation = { id: a.id, page_id: a.page_id, kind: a.kind, x: a.x, y: a.y };
      if (a.points) out.points = a.points;
      if (a.text != null) out.text = a.text;
      if (a.question_id != null) out.question_id = a.question_id;
      return out;
    }),
  };
}

function compareOf(v: unknown): ReviewCompare | null {
  const c = obj(v);
  if (!c) return null;
  return {
    within: c.within === true,
    totalA: num(c.total_a),
    totalB: num(c.total_b),
    maxTotal: num(c.max_total),
    questions: list(c.questions).flatMap((q) => {
      const questionId = str(q.question_id);
      return questionId
        ? [{ questionId, label: str(q.label) ?? "", max: num(q.max), a: num(q.a), aNa: q.a_na === true, b: num(q.b), bNa: q.b_na === true, out: q.out === true }]
        : [];
    }),
  };
}

/** marking_review_open's answer, or the code it was refused with ("internal" when the answer makes no sense). Without
 * a second marking, the comparison is the first marks alone, question by question. */
export function parseReviewOpen(data: unknown): { ok: true; review: OpenedReview } | { ok: false; code: string } {
  const d = obj(data);
  if (d?.ok !== true) return refusal(d);
  const r = obj(d.review);
  const u = obj(d.unit);
  const s = obj(d.structure);
  const id = str(r?.id);
  const unitId = str(u?.id);
  const first = markingOf(d.first);
  if (!r || !u || !s || !id || !unitId || !first || !isKind(r.kind)) return { ok: false, code: "internal" };
  const questions: ReviewQuestion[] = parseQuestions(s.questions).map((q) => ({
    id: q.id, parentId: q.parentId, label: q.label, leaf: q.leaf, maxMark: q.maxMark, step: q.step, optionGroupId: q.optionGroupId,
  }));
  const second = markingOf(d.second);
  const firstMarks = new Map(first.marks.map((m) => [m.questionId, m]));
  const compare = (second ? compareOf(d.compare) : null) ?? {
    within: true,
    totalA: first.total,
    totalB: null,
    maxTotal: null,
    questions: questions.filter((q) => q.leaf).map((q) => {
      const m = firstMarks.get(q.id);
      return { questionId: q.id, label: q.label, max: q.maxMark, a: m?.mark ?? null, aNa: m?.na ?? false, b: null, bNa: false, out: false };
    }),
  };
  return {
    ok: true,
    review: {
      review: { id, kind: r.kind, open: r.state === "open", outcome: str(r.outcome), party: r.party === true },
      unit: {
        id: unitId,
        examTitle: str(u.exam_title) ?? "",
        paper: str(u.paper) ?? "",
        scriptNumber: str(u.script_number) ?? "",
        indexNumber: str(u.index_number),
        groupLabel: str(u.group_label),
      },
      questions,
      optionGroups: list(s.option_groups).flatMap((o) => {
        const oid = str(o.id);
        const choose = num(o.choose);
        return oid && choose !== null ? [{ id: oid, label: str(o.label) ?? "", choose }] : [];
      }),
      pages: list(d.pages).flatMap((p) => {
        const pageId = str(p.page_id);
        const n = num(p.n);
        return pageId && n !== null ? [{ n, page_id: pageId }] : [];
      }),
      first,
      second,
      compare,
      final: list(d.final).flatMap((f) => {
        const questionId = str(f.question_id);
        return questionId ? [{ questionId, mark: num(f.mark), na: f.na === true, source: str(f.source) }] : [];
      }),
    },
  };
}

export type ReviewRow = { label: string; max: number; first: string; second: string; final: string; out: boolean };

/** The review table, in paper order: each question with its maximum, both markers' marks, the final mark (a dash while
 * there is none) and whether the two markings differ by more than the tolerance there ("Different"). */
export function reviewRows(compare: ReviewCompare, final: FinalMark[]): ReviewRow[] {
  const finals = new Map(final.map((f) => [f.questionId, f]));
  return compare.questions.map((q) => {
    const f = finals.get(q.questionId);
    return {
      label: q.label,
      max: q.max ?? 0,
      first: markText(q.a, q.aNa),
      second: markText(q.b, q.bNa),
      final: f ? markText(f.mark, f.na) : "–",
      out: q.out,
    };
  });
}

/** A mark as a server action sends it. */
export type MarkInput = { question_id: string; mark: number | null; na: boolean };
/** One mark box of the page: what was typed, and NR. */
export type MarkBox = { text: string; na: boolean };

/** The marks of the page's boxes, one per question that takes marks: each a mark within the question's maximum and
 * step, or NR. A question left empty, or a mark it does not allow, is refused with a sentence that names it, before
 * the server is asked (it refuses them too, in fewer words). */
export function readMarks(
  questions: Pick<ReviewQuestion, "id" | "label" | "leaf" | "maxMark" | "step">[],
  boxes: Record<string, MarkBox | undefined>,
): { ok: true; marks: MarkInput[] } | { ok: false; message: string } {
  const marks: MarkInput[] = [];
  const missing: string[] = [];
  for (const q of questions.filter((x) => x.leaf)) {
    const box = boxes[q.id];
    if (box?.na) {
      marks.push({ question_id: q.id, mark: null, na: true });
      continue;
    }
    const text = (box?.text ?? "").trim();
    if (text === "") {
      missing.push(q.label);
      continue;
    }
    const value = Number(text);
    const max = q.maxMark ?? 0;
    if (!validMark(value, max, q.step)) {
      return { ok: false, message: `The mark for ${q.label} must be from 0 to ${max}, ${q.step === 0.5 ? "in half marks" : "in whole marks"}.` };
    }
    marks.push({ question_id: q.id, mark: value, na: false });
  }
  if (missing.length > 0) return { ok: false, message: `${reviewMessageFor("incomplete")} Still to mark: ${labelList(missing)}.` };
  return { ok: true, marks };
}

/** Of the marks of the page, those that differ from the marks they started from (the final marks, or the first marks
 * while there are none): only these are sent as a final mark change, so the others keep where they came from. */
export function changedMarks(marks: MarkInput[], from: ReviewMark[]): MarkInput[] {
  const was = new Map(from.map((m) => [m.questionId, m]));
  return marks.filter((m) => {
    const w = was.get(m.question_id);
    return !w || w.na !== m.na || (!m.na && w.mark !== m.mark);
  });
}

/** A note to a marker, or on a practice or seeded script: 3 to 1,000 characters once trimmed. `required` false: it may
 * be left out. */
export function noteProblem(note: string, required: boolean): string | null {
  const n = note.trim().length;
  if (n === 0 && !required) return null;
  return n < 3 || n > 1000 ? NOTE_PROBLEM : null;
}
export const NOTE_PROBLEM = "Write a note of 3 to 1,000 characters.";

export type PracticeAttempt = { standardId: string; scriptNumber: string; total: number | null; leadTotal: number | null; maxTotal: number | null; within: boolean };
export type ExamMarker = {
  markerId: string;
  name: string;
  lead: boolean;
  cleared: boolean;
  paused: boolean;
  misses: number;
  practice: PracticeAttempt[];
  /** The practice scripts they may still do (0 once cleared). */
  practiceLeft: number;
};
export type ExamMarkers = { markers: ExamMarker[] };

/** marking_exam_markers's answer, or the code it was refused with. A marker with no name is "Marker" and the start of
 * their id, as the other lists say it. */
export function parseExamMarkers(data: unknown): ({ ok: true } & ExamMarkers) | { ok: false; code: string } {
  const d = obj(data);
  if (d?.ok !== true) return refusal(d);
  return {
    ok: true,
    markers: list(d.markers).flatMap((m) => {
      const markerId = str(m.marker_id);
      if (!markerId) return [];
      return [{
        markerId,
        name: str(m.name) ?? `Marker ${markerId.slice(0, 8)}`,
        lead: m.lead === true,
        cleared: m.cleared === true,
        paused: m.paused === true,
        misses: count(m.misses),
        practice: list(m.practice).flatMap((p) => {
          const standardId = str(p.standard_id);
          return standardId
            ? [{ standardId, scriptNumber: str(p.script_number) ?? "", total: num(p.total), leadTotal: num(p.lead_total), maxTotal: num(p.max_total), within: p.within === true }]
            : [];
        }),
        practiceLeft: count(m.practice_left),
      }];
    }),
  };
}

/** "Cleared", or where a marker's practice stands: "Practice: 2 of 3 done". */
export function clearanceText(m: Pick<ExamMarker, "cleared" | "practice" | "practiceLeft">): string {
  if (m.cleared) return "Cleared";
  return `Practice: ${m.practice.length} of ${m.practice.length + m.practiceLeft} done`;
}

export type StandardUse = "practice" | "seed";
export type Standard = {
  id: string;
  unitId: string;
  use: StandardUse;
  scriptNumber: string;
  indexNumber: string | null;
  groupLabel: string | null;
  total: number | null;
  maxTotal: number | null;
  note: string | null;
  retired: boolean;
  /** Submitted attempts, and those outside (a seeded script: a miss; practice: outside tolerance). */
  attempts: { done: number; outside: number };
};
export type StandardCandidate = { unitId: string; scriptNumber: string; indexNumber: string | null; groupLabel: string | null; total: number | null };

/** marking_standards_list's answer, or the code it was refused with. canAdd (the lead's own submitted pieces that may
 * become practice or seeded scripts) is null for an admin, whom the function does not give it. */
export function parseStandards(
  data: unknown,
): { ok: true; standards: Standard[]; canAdd: StandardCandidate[] | null; more: boolean } | { ok: false; code: string } {
  const d = obj(data);
  if (d?.ok !== true) return refusal(d);
  return {
    ok: true,
    standards: list(d.standards).flatMap((s) => {
      const id = str(s.id);
      const unitId = str(s.unit_id);
      if (!id || !unitId || (s.use !== "practice" && s.use !== "seed")) return [];
      const a = obj(s.attempts) ?? {};
      return [{
        id,
        unitId,
        use: s.use,
        scriptNumber: str(s.script_number) ?? "",
        indexNumber: str(s.index_number),
        groupLabel: str(s.group_label),
        total: num(s.total),
        maxTotal: num(s.max_total),
        note: str(s.note),
        retired: s.retired === true,
        attempts: { done: count(a.done), outside: count(a.outside) },
      }];
    }),
    canAdd: Array.isArray(d.can_add)
      ? list(d.can_add).flatMap((c) => {
          const unitId = str(c.unit_id);
          return unitId
            ? [{ unitId, scriptNumber: str(c.script_number) ?? "", indexNumber: str(c.index_number), groupLabel: str(c.group_label), total: num(c.total) }]
            : [];
        })
      : null,
    more: d.more === true,
  };
}
