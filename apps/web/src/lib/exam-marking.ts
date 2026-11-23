/** Opening marking for an exam: what the admin exam page reads from marking_exam_get and marking_checks_get and says
 * about it in plain words. The database re-checks every rule (marking_settings_set, marking_checks_set, marking_open,
 * marking_close, marking_reopen). */

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

/** The checks on an exam's marking, as marking_checks_set takes them. */
export type CheckSettings = {
  doubleMarking: boolean;
  /** Second-mark this % of scripts (1 to 100). */
  samplePercent: number;
  /** Send to the lead marker when marks differ by more than this % of the maximum (1 to 50). */
  tolerancePercent: number;
  seeds: boolean;
  /** About one seeded script in every this many (3 to 50). */
  seedEvery: number;
  practice: boolean;
};

/** marking_checks_get's answer. */
export type ChecksView = CheckSettings & {
  /** Who last turned the checks off and when, and why (admins only: a lead marker is never given the reason); null
   * when nothing is turned off. */
  off: { reason: string | null; byName: string | null; at: string } | null;
  /** Approved active markers of the exam's subject. */
  markersApproved: number;
  /** The checks may be turned off: the subject has at most one approved marker. */
  canSwitchOff: boolean;
  opened: boolean;
  approved: boolean;
};

const whole = (v: unknown, lo: number, hi: number): number | null => (typeof v === "number" && Number.isInteger(v) && v >= lo && v <= hi ? v : null);

/** marking_checks_get's answer, or null when it is not one. */
export function parseChecksView(data: unknown): ChecksView | null {
  const d = obj(data);
  if (!d || d.ok !== true) return null;
  const samplePercent = whole(d.sample_percent, 1, 100);
  const tolerancePercent = whole(d.tolerance_percent, 1, 50);
  const seedEvery = whole(d.seed_every, 3, 50);
  if (samplePercent === null || tolerancePercent === null || seedEvery === null) return null;
  const off = obj(d.off);
  const at = off ? time(off.at) : null;
  return {
    doubleMarking: d.double_marking === true,
    samplePercent,
    tolerancePercent,
    seeds: d.seeds === true,
    seedEvery,
    practice: d.practice === true,
    off: off && at ? { reason: typeof off.reason === "string" ? off.reason : null, byName: typeof off.by_name === "string" ? off.by_name : null, at } : null,
    markersApproved: num(d.markers_approved),
    canSwitchOff: d.can_switch_off === true,
    opened: d.opened === true,
    approved: d.approved === true,
  };
}

/** Why these checks cannot be saved as they are (null: they can): each number whole and in range. */
export function checksProblem(s: CheckSettings): string | null {
  if (whole(s.samplePercent, 1, 100) === null) return "Enter a whole number from 1 to 100 for the scripts second-marked.";
  if (whole(s.tolerancePercent, 1, 50) === null) return "The difference that goes to the lead marker is a whole number from 1 to 50%.";
  if (whole(s.seedEvery, 3, 50) === null) return "Enter a whole number from 3 to 50 for how often a seeded script comes.";
  return null;
}

/** Whether saving `next` over what is saved changes anything. */
export function checksChanged(saved: CheckSettings, next: CheckSettings): boolean {
  return (
    saved.doubleMarking !== next.doubleMarking ||
    saved.samplePercent !== next.samplePercent ||
    saved.tolerancePercent !== next.tolerancePercent ||
    saved.seeds !== next.seeds ||
    saved.seedEvery !== next.seedEvery ||
    saved.practice !== next.practice
  );
}

/** Whether saving `next` turns one of the three checks off. */
export function checksTurnOff(saved: CheckSettings, next: CheckSettings): boolean {
  return (saved.doubleMarking && !next.doubleMarking) || (saved.seeds && !next.seeds) || (saved.practice && !next.practice);
}

/** Whether the database will ask for a reason: a check turned off, or any change once marking has opened. */
export function checksNeedReason(saved: ChecksView, next: CheckSettings): boolean {
  return checksTurnOff(saved, next) || (saved.opened && checksChanged(saved, next));
}

const UK_DATE = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", day: "numeric", month: "long", year: "numeric" });

/** "Turned off by Ada Checker on 3 December 2026: Only one marker for this subject" (the date in UK time); without
 * the reason (a lead marker's view), "Checks were turned off by Ada Checker on 3 December 2026." */
export function checksOffLine(off: NonNullable<ChecksView["off"]>): string {
  const who = off.byName ?? "a member of staff";
  const day = UK_DATE.format(new Date(off.at));
  return off.reason === null ? `Checks were turned off by ${who} on ${day}.` : `Turned off by ${who} on ${day}: ${off.reason}`;
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
