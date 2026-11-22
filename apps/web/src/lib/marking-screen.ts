/** What the marking screen reads from marking_unit_open, in the screen's own shape, and the small rules the screen
 * draws with: full question labels ("2(b)(i)"), a question's pages, a mark in plain words, and the zoom steps. The
 * parser keeps only the fields it knows, so nothing else reaches the screen; the function itself names no candidate
 * (the index number only, Ruling R4). The database checks every rule again. */
import type { AnnotationKind } from "@/lib/annotations";
import { ANNOTATION_KINDS } from "@/lib/annotations";
import { markButtons, type MarkEntry } from "@/lib/marking-marks";
import type { OpenedMarking } from "@/lib/marking-model";
import { ZOOM_MAX, ZOOM_MIN } from "@/lib/marking-pointer";

export type ScreenPoint = { id: string; label: string | null; marks: number; marksTo: number | null; text: string };
export type ScreenQuestion = {
  id: string;
  parentId: string | null;
  /** As printed on the paper: "2(b)(i)". */
  label: string;
  /** 0 for a question, 1 for a part, 2 for a part of a part. */
  depth: number;
  /** Only the lowest questions carry marks. */
  leaf: boolean;
  maxMark: number | null;
  step: 0.5 | 1;
  levels: boolean;
  /** Paper pages (copy pages) the question is answered on. */
  pages: number[];
  optionGroupId: string | null;
  guidance: string;
  alternatives: string;
  points: ScreenPoint[];
};
export type ScreenPage = { n: number; pageId: string; copyPage: number | null; extra: boolean; markingPath: string | null; rotation: number };
export type MarkingStatus = "in_progress" | "submitted" | "set_aside";
export type OpenedPiece = {
  unit: {
    id: string;
    examTitle: string;
    paper: string;
    scriptNumber: string;
    indexNumber: string | null;
    groupLabel: string | null;
    holdUntil: string | null;
    closed: boolean;
  };
  marking: { id: string; rev: number; status: MarkingStatus; pagesChanged: boolean };
  questions: ScreenQuestion[];
  optionGroups: { id: string; label: string; choose: number }[];
  markSchemePath: string | null;
  pages: ScreenPage[];
  /** The saved marks, note and annotations, for the marking model (fromServer). */
  saved: OpenedMarking;
};

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const list = (v: unknown): Obj[] => (Array.isArray(v) ? v.map(obj).filter((x): x is Obj => x !== null) : []);
const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const KINDS = new Set<string>(ANNOTATION_KINDS);
const isPoint = (p: unknown): p is [number, number] => Array.isArray(p) && p.length === 2 && p.every((n) => typeof n === "number" && Number.isFinite(n));

/** marking_unit_open's answer: the piece, or the code it was refused with ("internal" when the answer makes no sense). */
export function parseOpened(data: unknown): { ok: true; piece: OpenedPiece } | { ok: false; code: string } {
  const d = obj(data);
  if (!d) return { ok: false, code: "internal" };
  if (d.ok !== true) return { ok: false, code: str(d.code) ?? "internal" };
  const u = obj(d.unit);
  const m = obj(d.marking);
  const s = obj(d.structure);
  const unitId = str(u?.id);
  const markingId = str(m?.id);
  const rev = num(m?.rev);
  const status = str(m?.status);
  if (!u || !m || !s || !unitId || !markingId || rev === null || (status !== "in_progress" && status !== "submitted" && status !== "set_aside")) {
    return { ok: false, code: "internal" };
  }

  const rows = list(s.questions).filter((q) => str(q.id) && str(q.label));
  const byId = new Map(rows.map((q) => [q.id as string, q]));
  const hasChild = new Set(rows.flatMap((q) => (str(q.parent_id) ? [q.parent_id as string] : [])));
  const fullLabel = (q: Obj): { label: string; depth: number } => {
    const chain: string[] = [];
    let cur: Obj | undefined = q;
    const seen = new Set<string>();
    while (cur && !seen.has(cur.id as string)) {
      seen.add(cur.id as string);
      chain.unshift(cur.label as string);
      cur = str(cur.parent_id) ? byId.get(cur.parent_id as string) : undefined;
    }
    return { label: chain[0] + chain.slice(1).map((l) => `(${l})`).join(""), depth: chain.length - 1 };
  };
  const questions: ScreenQuestion[] = rows.map((q) => {
    const { label, depth } = fullLabel(q);
    const pages = Array.isArray(q.pages) ? q.pages.filter((p): p is number => typeof p === "number" && Number.isInteger(p)) : [];
    return {
      id: q.id as string,
      parentId: str(q.parent_id),
      label,
      depth,
      leaf: !hasChild.has(q.id as string),
      maxMark: num(q.max_mark),
      step: num(q.mark_step) === 0.5 ? 0.5 : 1,
      levels: q.levels === true,
      pages,
      optionGroupId: str(q.option_group_id),
      guidance: str(q.guidance) ?? "",
      alternatives: str(q.alternatives) ?? "",
      points: list(q.points).flatMap((p) => {
        const id = str(p.id);
        const marks = num(p.marks);
        const text = str(p.text);
        return id && marks !== null && text !== null ? [{ id, label: str(p.label), marks, marksTo: num(p.marks_to), text }] : [];
      }),
    };
  });

  const pages: ScreenPage[] = list(d.pages).flatMap((p) => {
    const pageId = str(p.page_id);
    const n = num(p.n);
    if (!pageId || n === null) return [];
    return [{ n, pageId, copyPage: num(p.copy_page), extra: p.extra === true, markingPath: str(p.marking_path), rotation: num(p.rotation) ?? 0 }];
  });

  const saved: OpenedMarking = {
    marking: { lead_note: str(m.lead_note) },
    marks: list(d.marks).flatMap((x) => {
      const q = str(x.question_id);
      return q ? [{ question_id: q, mark: num(x.mark), na: x.na === true }] : [];
    }),
    annotations: list(d.annotations).flatMap((a) => {
      const id = str(a.id);
      const pageId = str(a.page_id);
      const kind = str(a.kind);
      const x = num(a.x);
      const y = num(a.y);
      if (!id || !pageId || !kind || !KINDS.has(kind) || x === null || y === null) return [];
      return [{
        id,
        page_id: pageId,
        kind: kind as AnnotationKind,
        x,
        y,
        points: Array.isArray(a.points) && a.points.every(isPoint) ? (a.points as [number, number][]) : null,
        text: str(a.text),
        question_id: str(a.question_id),
      }];
    }),
  };

  const file = obj(s.mark_scheme_file);
  return {
    ok: true,
    piece: {
      unit: {
        id: unitId,
        examTitle: str(u.exam_title) ?? "",
        paper: str(u.paper) ?? "",
        scriptNumber: str(u.script_number) ?? "",
        indexNumber: str(u.index_number),
        groupLabel: str(u.group_label),
        holdUntil: str(u.hold_until),
        closed: u.closed === true,
      },
      marking: { id: markingId, rev, status, pagesChanged: m.pages_changed === true },
      questions,
      optionGroups: list(s.option_groups).flatMap((o) => {
        const id = str(o.id);
        const choose = num(o.choose);
        return id && choose !== null ? [{ id, label: str(o.label) ?? "", choose }] : [];
      }),
      markSchemePath: str(file?.storage_path),
      pages,
      saved,
    },
  };
}

/** A mark as the marker reads it: "3", "2.5", "NR", or a dash for none yet. */
export function markText(entry: MarkEntry | undefined): string {
  if (!entry) return "–";
  if (entry.na) return "NR";
  return entry.mark === null ? "–" : formatMark(entry.mark);
}

export function formatMark(n: number): string {
  return Number.isInteger(n) ? String(n) : n.toFixed(1);
}

/** The question and everything under it. */
function family(q: ScreenQuestion, questions: ScreenQuestion[]): ScreenQuestion[] {
  const out = [q];
  for (let i = 0; i < out.length; i++) out.push(...questions.filter((c) => c.parentId === out[i].id));
  return out;
}

/** A question's mark so far: a leaf's own mark; for a question with parts, the sum of its parts' marks once any part
 * has one ("NR" when every part is NR), else a dash. */
export function questionMarkText(q: ScreenQuestion, questions: ScreenQuestion[], marks: Record<string, MarkEntry>): string {
  if (q.leaf) return markText(marks[q.id]);
  const leaves = family(q, questions).filter((x) => x.leaf);
  const given = leaves.map((l) => marks[l.id]).filter((m): m is MarkEntry => !!m && (m.na || m.mark !== null));
  if (given.length === 0) return "–";
  if (given.every((m) => m.na) && given.length === leaves.length) return "NR";
  return formatMark(given.reduce((sum, m) => sum + (m.na || m.mark === null ? 0 : m.mark), 0));
}

/** The indexes (in `pages`) of the pages a question, or any of its parts, is answered on. */
export function questionPageIndexes(q: ScreenQuestion | undefined, questions: ScreenQuestion[], pages: ScreenPage[]): number[] {
  if (!q) return [];
  const wanted = new Set(family(q, questions).flatMap((x) => x.pages));
  return pages.flatMap((p, i) => (p.copyPage !== null && wanted.has(p.copyPage) ? [i] : []));
}

/** The question to mark when a question in the list is chosen: itself, or its first part to mark. */
export function firstLeaf(q: ScreenQuestion, questions: ScreenQuestion[]): ScreenQuestion {
  return family(q, questions).find((x) => x.leaf) ?? q;
}

/** How a question's mark is given: the buttons (none when there would be more than 21), and the number box, shown
 * whenever the maximum is over 9 (beside the buttons), since a digit key then goes to the box (keyAction). */
export function markControls(max: number, step: 0.5 | 1): { buttons: number[] | null; box: boolean } {
  const buttons = markButtons(max, step);
  return { buttons, box: buttons === null || max > 9 };
}

/** Zoom steps of the zoom buttons and keys (1 is the page's width fitting the area). */
export const ZOOM_STEPS = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3, 4] as const;

export function zoomStepIn(z: number): number {
  return ZOOM_STEPS.find((v) => v > z + 1e-6) ?? ZOOM_MAX;
}

export function zoomStepOut(z: number): number {
  return [...ZOOM_STEPS].reverse().find((v) => v < z - 1e-6) ?? ZOOM_MIN;
}

/** At most `max` labels, then "and N more". */
export function labelList(labels: string[], max = 6): string {
  if (labels.length <= max) return labels.join(", ");
  return `${labels.slice(0, max).join(", ")} and ${labels.length - max} more`;
}
