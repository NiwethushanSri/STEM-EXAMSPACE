/** Opening marking for an exam: what the admin exam page reads from marking_exam_get and says about it in plain
 * words. The database re-checks every rule (marking_settings_set, marking_open, marking_close, marking_reopen). */

export type MarkingMode = "whole" | "by_question";

export type MarkingView = {
  mode: MarkingMode;
  deadline: string | null;
  openedAt: string | null;
  closedAt: string | null;
  structure: { version: number; leaves: number; maxTotal: number; ungrouped: number };
  /** Approved active markers of the exam's subject. */
  markers: number;
  scripts: { verified: number; readyToMark: number; marking: number; marked: number };
  /** Scripts held back, by the first thing holding each back. pictureUnchecked: a marking picture of the script waits
   * for staff to check it (Phase 3A Task 8). */
  waiting: {
    homeWindowOpen: number;
    centrePagesUnsettled: number;
    picturesUpdating: number;
    lateUndecided: number;
    takenBack: number;
    pictureUnchecked: number;
  };
};

/** A question group with the labels of its questions, in paper order. */
export type MarkingGroup = { id: string; label: string; questions: string[] };

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);
const time = (v: unknown): string | null => (typeof v === "string" && !Number.isNaN(Date.parse(v)) ? v : null);

/** marking_exam_get's answer, or null when it is not one. */
export function parseMarkingView(data: unknown): MarkingView | null {
  const d = obj(data);
  if (!d || d.ok !== true) return null;
  const s = obj(d.structure) ?? {};
  const sc = obj(d.scripts) ?? {};
  const w = obj(d.waiting) ?? {};
  return {
    mode: d.mode === "by_question" ? "by_question" : "whole",
    deadline: time(d.deadline),
    openedAt: time(d.opened_at),
    closedAt: time(d.closed_at),
    structure: { version: num(s.version), leaves: num(s.leaves), maxTotal: num(s.max_total), ungrouped: num(s.ungrouped) },
    markers: num(d.markers),
    scripts: { verified: num(sc.verified), readyToMark: num(sc.ready_to_mark), marking: num(sc.marking), marked: num(sc.marked) },
    waiting: {
      homeWindowOpen: num(w.home_window_open),
      centrePagesUnsettled: num(w.centre_pages_unsettled),
      picturesUpdating: num(w.pictures_updating),
      lateUndecided: num(w.late_undecided),
      takenBack: num(w.taken_back),
      pictureUnchecked: num(w.picture_unchecked),
    },
  };
}

const DAY_TIME = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/London",
  day: "numeric",
  month: "long",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

/** "3 December, 12:30" in UK time. */
export function dayAndTime(iso: string): string {
  const p = Object.fromEntries(DAY_TIME.formatToParts(new Date(iso)).map((x) => [x.type, x.value]));
  return `${p.day} ${p.month}, ${p.hour}:${p.minute}`;
}

/** When home scripts may be handed out: the exam's finish + 24 hours. */
export function homeWindowEnds(startsAt: string, durationMinutes: number): string {
  return new Date(Date.parse(startsAt) + (durationMinutes + 24 * 60) * 60000).toISOString();
}

/** "1 question", "3 questions", "10.5 marks". */
const count = (n: number, one: string, many: string) => `${Number(n.toFixed(1))} ${n === 1 ? one : many}`;

/** The checks before and during marking, one plain line each: "3 questions, 60 marks", "2 markers approved",
 * "12 scripts verified", "4 home scripts wait until 3 December, 12:30", "2 centre scripts wait for pages in the queue". */
export function markingChecks(v: MarkingView, homeUntil: string): string[] {
  const out: string[] = [];
  const s = v.structure;
  out.push(s.leaves === 0 ? "No questions yet" : `${count(s.leaves, "question", "questions")}, ${count(s.maxTotal, "mark", "marks")}`);
  if (v.mode === "by_question" && s.ungrouped > 0) out.push(`${count(s.ungrouped, "question is", "questions are")} not in a group`);
  out.push(v.markers === 0 ? "No markers approved for this subject" : `${count(v.markers, "marker", "markers")} approved`);
  out.push(`${count(v.scripts.verified, "script", "scripts")} verified`);
  if (v.openedAt) out.push(`${v.scripts.readyToMark} ready to mark, ${v.scripts.marking} being marked, ${v.scripts.marked} marked`);
  const w = v.waiting;
  if (w.homeWindowOpen > 0) out.push(`${count(w.homeWindowOpen, "home script waits", "home scripts wait")} until ${dayAndTime(homeUntil)}`);
  if (w.centrePagesUnsettled > 0) out.push(`${count(w.centrePagesUnsettled, "centre script waits", "centre scripts wait")} for pages in the queue`);
  if (w.picturesUpdating > 0) {
    out.push(w.picturesUpdating === 1 ? "1 script waits while its pictures are updated" : `${w.picturesUpdating} scripts wait while their pictures are updated`);
  }
  if (w.pictureUnchecked > 0) {
    out.push(`${w.pictureUnchecked} ${w.pictureUnchecked === 1 ? "script's" : "scripts'"} marking pictures wait for a staff check`);
  }
  if (w.lateUndecided > 0) out.push(`${count(w.lateUndecided, "late script waits", "late scripts wait")} for a decision`);
  if (w.takenBack > 0) out.push(`${count(w.takenBack, "script was", "scripts were")} taken back from marking`);
  return out;
}
