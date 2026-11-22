const EPS = 1e-9;

/** A mark the question allows: from 0 to its maximum, in whole steps. */
export function validMark(value: number, max: number, step: 0.5 | 1): boolean {
  if (!Number.isFinite(value) || value < 0 || value > max + EPS) return false;
  return Math.abs(value / step - Math.round(value / step)) < EPS;
}

/** Every allowed mark as a button, or null when there would be more than 21 (the marker types the mark instead). */
export function markButtons(max: number, step: 0.5 | 1): number[] | null {
  const count = Math.floor(max / step + EPS) + 1;
  if (count > 21) return null;
  return Array.from({ length: count }, (_, i) => i * step);
}

export type MarkQuestion = { id: string; parent_id: string | null; label?: string; max_mark: number | null; option_group_id: string | null };
export type MarkEntry = { mark: number | null; na: boolean };
export type MarkOptionGroup = { id: string; label?: string; choose: number };

/**
 * What a piece is out of and what it has so far. Only the lowest questions carry marks. Where a set of optional
 * questions says "answer N of these", only the best N count towards both numbers, as the database counts them.
 * `missing` lists the questions still to mark (a blank, not "not attempted"), in paper order; optional questions the
 * candidate did not choose are not missing once N are marked. `whole` is accepted for the caller's two cases (a whole
 * script and a question group): the database counts both the same way, so it changes nothing here.
 */
export function unitTotal(
  questions: MarkQuestion[],
  marks: Record<string, MarkEntry>,
  optionGroups: MarkOptionGroup[],
  whole: boolean,
): { total: number; max: number; missing: string[] } {
  void whole;
  const hasChild = new Set(questions.flatMap((q) => (q.parent_id ? [q.parent_id] : [])));
  const byId = new Map(questions.map((q) => [q.id, q]));
  const topOf = (q: MarkQuestion): MarkQuestion => {
    let cur = q;
    while (cur.parent_id && byId.has(cur.parent_id)) cur = byId.get(cur.parent_id)!;
    return cur;
  };
  type Top = { top: MarkQuestion; total: number; max: number; touched: boolean; blanks: string[] };
  const tops = new Map<string, Top>();
  for (const q of questions) {
    if (hasChild.has(q.id)) continue;
    const top = topOf(q);
    const t = tops.get(top.id) ?? { top, total: 0, max: 0, touched: false, blanks: [] };
    const m = marks[q.id];
    t.max += q.max_mark ?? 0;
    if (m && !m.na && m.mark !== null) t.total += m.mark;
    if (m && (m.na || m.mark !== null)) t.touched = true;
    else t.blanks.push(q.id);
    tops.set(top.id, t);
  }
  let total = 0;
  let max = 0;
  const missing = new Set<string>();
  const sets = new Map<string, Top[]>();
  for (const t of tops.values()) {
    const g = t.top.option_group_id;
    if (g) sets.set(g, [...(sets.get(g) ?? []), t]);
    else {
      total += t.total;
      max += t.max;
      t.blanks.forEach((id) => missing.add(id));
    }
  }
  for (const [g, list] of sets) {
    const choose = Math.max(0, optionGroups.find((o) => o.id === g)?.choose ?? list.length);
    total += list.map((t) => t.total).sort((a, b) => b - a).slice(0, choose).reduce((a, b) => a + b, 0);
    max += list.map((t) => t.max).sort((a, b) => b - a).slice(0, choose).reduce((a, b) => a + b, 0);
    const started = list.filter((t) => t.touched).length;
    for (const t of list) {
      if (t.touched || started < choose) t.blanks.forEach((id) => missing.add(id));
    }
  }
  const order = questions.map((q) => q.id);
  return { total, max, missing: order.filter((id) => missing.has(id)) };
}

/** The question before or after `current`, stopping at the first and last. */
export function nextQuestionId(leaves: { id: string }[], current: string, dir: 1 | -1): string {
  const i = leaves.findIndex((l) => l.id === current);
  if (i === -1) return leaves[0]?.id ?? current;
  return leaves[Math.min(leaves.length - 1, Math.max(0, i + dir))].id;
}
