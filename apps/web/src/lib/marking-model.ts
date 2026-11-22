import type { AnnotationKind } from "./annotations";

export type SavedAnnotation = {
  id: string;
  page_id: string;
  kind: AnnotationKind;
  x: number;
  y: number;
  points?: [number, number][];
  text?: string;
  question_id?: string | null;
};

export type Op =
  | { op: "mark"; question_id: string; mark: number | null; na: boolean }
  | ({ op: "ann_put" } & SavedAnnotation)
  | { op: "ann_del"; id: string }
  | { op: "ann_restore"; id: string }
  | { op: "note"; text: string };

export type MarkingState = {
  marks: Record<string, { mark: number | null; na: boolean }>;
  annotations: SavedAnnotation[];
  deleted: SavedAnnotation[];
  note: string;
  // Each entry is the operations that undo (or redo) one action, in the order to apply them.
  undo: Op[][];
  redo: Op[][];
};

/** The parts of marking_unit_open's answer the model reads. */
export type OpenedMarking = {
  marking?: { lead_note?: string | null };
  marks?: { question_id: string; mark: number | null; na: boolean }[];
  annotations?: {
    id: string;
    page_id: string;
    kind: AnnotationKind;
    x: number;
    y: number;
    points?: [number, number][] | null;
    text?: string | null;
    question_id?: string | null;
  }[];
};

function clean(a: OpenedMarking["annotations"] extends (infer T)[] | undefined ? T : never): SavedAnnotation {
  const out: SavedAnnotation = { id: a.id, page_id: a.page_id, kind: a.kind, x: a.x, y: a.y };
  if (a.points) out.points = a.points;
  if (a.text !== null && a.text !== undefined) out.text = a.text;
  if (a.question_id !== null && a.question_id !== undefined) out.question_id = a.question_id;
  return out;
}

export function fromServer(opened: OpenedMarking): MarkingState {
  const marks: MarkingState["marks"] = {};
  for (const m of opened.marks ?? []) marks[m.question_id] = { mark: m.mark, na: m.na };
  return {
    marks,
    annotations: (opened.annotations ?? []).map(clean),
    deleted: [],
    note: opened.marking?.lead_note ?? "",
    undo: [],
    redo: [],
  };
}

const toAnnotation = (op: Extract<Op, { op: "ann_put" }>): SavedAnnotation => {
  const { op: _op, ...rest } = op;
  void _op;
  return rest;
};

function applyOne(s: MarkingState, op: Op): MarkingState {
  switch (op.op) {
    case "mark":
      return { ...s, marks: { ...s.marks, [op.question_id]: { mark: op.mark, na: op.na } } };
    case "ann_put": {
      const a = toAnnotation(op);
      const exists = s.annotations.some((x) => x.id === a.id);
      return {
        ...s,
        annotations: exists ? s.annotations.map((x) => (x.id === a.id ? a : x)) : [...s.annotations, a],
        deleted: s.deleted.filter((x) => x.id !== a.id),
      };
    }
    case "ann_del": {
      const gone = s.annotations.find((x) => x.id === op.id);
      if (!gone) return s;
      return { ...s, annotations: s.annotations.filter((x) => x.id !== op.id), deleted: [...s.deleted, gone] };
    }
    case "ann_restore": {
      const back = s.deleted.find((x) => x.id === op.id);
      if (!back) return s;
      return { ...s, deleted: s.deleted.filter((x) => x.id !== op.id), annotations: [...s.annotations, back] };
    }
    case "note":
      return { ...s, note: op.text };
  }
}

export function applyOps(s: MarkingState, ops: Op[]): MarkingState {
  return ops.reduce(applyOne, s);
}

/** The operation that undoes `op`, worked out against the state `op` is about to change. */
export function inverse(s: MarkingState, op: Op): Op {
  switch (op.op) {
    case "mark": {
      const prev = s.marks[op.question_id] ?? { mark: null, na: false };
      return { op: "mark", question_id: op.question_id, mark: prev.mark, na: prev.na };
    }
    case "ann_put": {
      const old = s.annotations.find((x) => x.id === op.id);
      return old ? { op: "ann_put", ...old } : { op: "ann_del", id: op.id };
    }
    case "ann_del":
      return { op: "ann_restore", id: op.id };
    case "ann_restore":
      return { op: "ann_del", id: op.id };
    case "note":
      return { op: "note", text: s.note };
  }
}

// The operations that undo `ops` applied in order from `s`: each one's inverse, last first.
function inversesOf(s: MarkingState, ops: Op[]): Op[] {
  const out: Op[] = [];
  let cur = s;
  for (const op of ops) {
    out.unshift(inverse(cur, op));
    cur = applyOne(cur, op);
  }
  return out;
}

/** A marker's action: apply it, remember how to undo it, forget anything that could be redone. */
export function act(s: MarkingState, ops: Op[]): { state: MarkingState; send: Op[] } {
  if (ops.length === 0) return { state: s, send: [] };
  const back = inversesOf(s, ops);
  const next = applyOps(s, ops);
  return { state: { ...next, undo: [...s.undo, back], redo: [] }, send: ops };
}

export function undo(s: MarkingState): { state: MarkingState; send: Op[] } {
  const entry = s.undo[s.undo.length - 1];
  if (!entry) return { state: s, send: [] };
  const forward = inversesOf(s, entry);
  const next = applyOps(s, entry);
  return { state: { ...next, undo: s.undo.slice(0, -1), redo: [...s.redo, forward] }, send: entry };
}

export function redo(s: MarkingState): { state: MarkingState; send: Op[] } {
  const entry = s.redo[s.redo.length - 1];
  if (!entry) return { state: s, send: [] };
  const back = inversesOf(s, entry);
  const next = applyOps(s, entry);
  return { state: { ...next, redo: s.redo.slice(0, -1), undo: [...s.undo, back] }, send: entry };
}

function distToSegment(px: number, py: number, a: [number, number], b: [number, number]): number {
  const dx = b[0] - a[0];
  const dy = b[1] - a[1];
  const len2 = dx * dx + dy * dy;
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, ((px - a[0]) * dx + (py - a[1]) * dy) / len2));
  return Math.hypot(px - (a[0] + t * dx), py - (a[1] + t * dy));
}

/** The marks on `pageId` that a stroke of the eraser passes within `radius` (a fraction of the page) of. */
export function erasedBy(
  path: [number, number][],
  annotations: SavedAnnotation[],
  pageId: string,
  radius = 0.012,
): string[] {
  if (path.length === 0) return [];
  return annotations
    .filter((a) => a.page_id === pageId)
    .filter((a) => {
      const shape: [number, number][] = a.points && a.points.length > 0 ? a.points : [[a.x, a.y]];
      return path.some((p, i) => {
        for (let j = 0; j < shape.length; j++) {
          const seg = shape.length === 1 ? ([shape[0], shape[0]] as const) : ([shape[j], shape[Math.min(j + 1, shape.length - 1)]] as const);
          if (distToSegment(p[0], p[1], seg[0], seg[1]) <= radius) return true;
        }
        // The eraser's own segment may cross a mark between two samples.
        const next = path[i + 1];
        if (!next) return false;
        return shape.some((q) => distToSegment(q[0], q[1], p, next) <= radius);
      });
    })
    .map((a) => a.id);
}

/** The length of a ruler line in centimetres on an A4 page (21.0 by 29.7), to one decimal place. */
export function rulerCm(points: [number, number][]): number {
  if (points.length < 2) return 0;
  const a = points[0];
  const b = points[points.length - 1];
  return Math.round(Math.hypot((b[0] - a[0]) * 21, (b[1] - a[1]) * 29.7) * 10) / 10;
}
