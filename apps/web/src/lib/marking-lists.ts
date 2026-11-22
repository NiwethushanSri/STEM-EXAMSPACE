/** The marker home (/marking) and the admin marking page (/admin/marking): what they read from marking_my_work,
 * marking_progress, marking_units_list and marking_alerts_list, and the hold, deadline and alert lines in plain words,
 * in UK time. Each parser keeps only the fields it knows, so nothing else reaches a page. No candidate name is read:
 * the functions give the script number and the index number only. The database checks every rule again. */
import { markingWorkMessageFor, releaseBlockedMessage, type AppRole } from "@stem/shared";
import { utcToLondonParts } from "@/lib/london-time";

/** Who may open /marking. The database decides who may mark (an approval) and who leads a subject. */
export const MARKING_ROLES = ["corrector", "teacher", "admin", "owner"] as const satisfies readonly AppRole[];

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/** "12 December, 17:00" in UK time (the clock change handled by london-time). */
export function ukDayTime(iso: string): string {
  const { date, time } = utcToLondonParts(iso);
  if (!date) return "";
  const [, month, day] = date.split("-").map(Number);
  return `${day} ${MONTHS[month - 1]}, ${time}`;
}

/** A marker's hold on a piece: "Held for you until 14:35" (a Next script hold, in UK time), "Assigned to you" (an
 * admin's assignment: no time limit) or "Hold ended". A hold lasts to its last moment, as the database reads it. */
export function holdText(holdUntil: string | null, now: Date): string {
  if (holdUntil === null) return "Assigned to you";
  const ms = Date.parse(holdUntil);
  if (Number.isNaN(ms) || ms < now.getTime()) return "Hold ended";
  return `Held for you until ${utcToLondonParts(holdUntil).time}`;
}

/** The marking deadline: "Mark by 12 December, 17:00" in UK time; overdue only once it has passed. */
export function deadlineText(deadline: string | null, now: Date): { text: string; overdue: boolean } {
  const ms = deadline === null ? NaN : Date.parse(deadline);
  if (Number.isNaN(ms)) return { text: "No deadline", overdue: false };
  return { text: `Mark by ${ukDayTime(deadline!)}`, overdue: now.getTime() > ms };
}

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const list = (v: unknown): Obj[] => (Array.isArray(v) ? v.map(obj).filter((x): x is Obj => x !== null) : []);
const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);
const str = (v: unknown): string | null => (typeof v === "string" ? v : typeof v === "number" ? String(v) : null);
const time = (v: unknown): string | null => (typeof v === "string" && !Number.isNaN(Date.parse(v)) ? v : null);
const pick = <T extends string>(v: unknown, allowed: readonly T[]): T | null => (allowed.includes(v as T) ? (v as T) : null);
/** The answer's payload when it is a success. */
const okAnswer = (data: unknown): Obj | null => {
  const d = obj(data);
  return d && d.ok === true ? d : null;
};

export type MarkingMode = "whole" | "by_question";
export type UnitState = "open" | "taken" | "submitted";
export const UNIT_STATES: readonly UnitState[] = ["open", "taken", "submitted"];
const HOW = ["next", "assigned"] as const;
export type HoldHow = (typeof HOW)[number];

export type MyWorkGroup = { id: string; label: string; left: number };
export type MyWorkExam = {
  examId: string;
  title: string;
  paper: string;
  subject: string;
  mode: MarkingMode;
  /** By question only: the groups, each with the pieces Next script could give the marker now. */
  groups: MyWorkGroup[];
  deadline: string | null;
  /** The database's view: the deadline passed, marking is open and work is left. */
  overdue: boolean;
  closed: boolean;
  left: number;
};
export type MyPiece = {
  unitId: string;
  examId: string;
  scriptNumber: string;
  indexNumber: string | null;
  groupLabel: string | null;
  state: UnitState;
  how: HoldHow | null;
  holdUntil: string | null;
  onHold: boolean;
  holdReason: string | null;
  pagesChanged: boolean;
  lastSavedAt: string | null;
};
export type MyWork = { approved: boolean; leadSubjects: number[]; exams: MyWorkExam[]; pieces: MyPiece[] };

/** marking_my_work's answer, or null when it is not one. */
export function parseMyWork(data: unknown): MyWork | null {
  const d = okAnswer(data);
  if (!d) return null;
  const exams: MyWorkExam[] = [];
  for (const e of list(d.exams)) {
    const examId = str(e.exam_id);
    if (!examId) continue;
    exams.push({
      examId,
      title: str(e.title) ?? "",
      paper: str(e.paper) ?? "",
      subject: str(e.subject) ?? "",
      mode: e.mode === "by_question" ? "by_question" : "whole",
      groups: list(e.groups).flatMap((g) => {
        const id = str(g.id);
        return id ? [{ id, label: str(g.label) ?? "", left: num(g.left) }] : [];
      }),
      deadline: time(e.deadline),
      overdue: e.overdue === true,
      closed: e.closed === true,
      left: num(e.left),
    });
  }
  const pieces: MyPiece[] = [];
  for (const p of list(d.pieces)) {
    const unitId = str(p.unit_id);
    const examId = str(p.exam_id);
    const state = pick(p.state, UNIT_STATES);
    if (!unitId || !examId || !state) continue;
    pieces.push({
      unitId,
      examId,
      scriptNumber: str(p.script_number) ?? "",
      indexNumber: str(p.index_number),
      groupLabel: str(p.group_label),
      state,
      how: pick(p.how, HOW),
      holdUntil: time(p.hold_until),
      onHold: p.on_hold === true,
      holdReason: str(p.hold_reason),
      pagesChanged: p.pages_changed === true,
      lastSavedAt: time(p.last_saved_at),
    });
  }
  return {
    approved: d.approved === true,
    leadSubjects: Array.isArray(d.lead_subjects) ? d.lead_subjects.filter((s): s is number => typeof s === "number") : [],
    exams,
    pieces,
  };
}

/** Where "Next script" on the marking screen looks: the exam of the piece on the screen and, for an exam marked by
 * question, its question group (found by its label, which is unique in an exam). Null when the piece is not in the
 * marker's list or the exam's marking has closed. */
export function nextScriptTarget(work: MyWork, unitId: string): { examId: string; groupId: string | null } | null {
  const piece = work.pieces.find((p) => p.unitId === unitId);
  const exam = piece ? work.exams.find((e) => e.examId === piece.examId) : undefined;
  if (!piece || !exam || exam.closed) return null;
  if (exam.mode !== "by_question") return { examId: exam.examId, groupId: null };
  const group = exam.groups.find((g) => g.label === piece.groupLabel);
  return group ? { examId: exam.examId, groupId: group.id } : null;
}

/** A marker's piece: "On hold", "Submitted" or "In progress" (held, or their hold ran out with it in progress). */
export function pieceStateLabel(p: MyPiece): string {
  if (p.onHold) return "On hold";
  return p.state === "submitted" ? "Submitted" : "In progress";
}

/** The line under a marker's piece about their hold, or null for a submitted one. A hold on a piece that is on hold
 * does not run out, so that piece says it is on hold instead. */
export function pieceHoldLine(p: MyPiece, now: Date): string | null {
  if (p.onHold) return markingWorkMessageFor("on_hold");
  if (p.state === "submitted") return null;
  // Their marking is in progress on a free piece: Next script gives it back to them.
  if (p.state === "open") return "Hold ended. Press Next script to carry on.";
  return holdText(p.holdUntil, now);
}

export type ProgressMarker = { markerId: string; name: string; taken: number; submitted: number; lastSavedAt: string | null };
export type ProgressExam = {
  examId: string;
  title: string;
  paper: string;
  subject: string;
  mode: MarkingMode;
  deadline: string | null;
  overdue: boolean;
  openedAt: string | null;
  closedAt: string | null;
  /** waiting: verified, not yet ready to mark. */
  scripts: { waiting: number; readyToMark: number; marking: number; marked: number };
  units: { open: number; taken: number; submitted: number; onHold: number };
  markers: ProgressMarker[];
  alertsOpen: number;
};

/** marking_progress's exams, or null when the answer is not one. */
export function parseProgress(data: unknown): ProgressExam[] | null {
  const d = okAnswer(data);
  if (!d) return null;
  const out: ProgressExam[] = [];
  for (const e of list(d.exams)) {
    const examId = str(e.exam_id);
    if (!examId) continue;
    const s = obj(e.scripts) ?? {};
    const u = obj(e.units) ?? {};
    out.push({
      examId,
      title: str(e.title) ?? "",
      paper: str(e.paper) ?? "",
      subject: str(e.subject) ?? "",
      mode: e.mode === "by_question" ? "by_question" : "whole",
      deadline: time(e.deadline),
      overdue: e.overdue === true,
      openedAt: time(e.opened_at),
      closedAt: time(e.closed_at),
      scripts: { waiting: num(s.waiting), readyToMark: num(s.ready_to_mark), marking: num(s.marking), marked: num(s.marked) },
      units: { open: num(u.open), taken: num(u.taken), submitted: num(u.submitted), onHold: num(u.on_hold) },
      markers: list(e.markers).flatMap((m) => {
        const markerId = str(m.marker_id);
        return markerId
          ? [{ markerId, name: str(m.name) ?? "Marker", taken: num(m.taken), submitted: num(m.submitted), lastSavedAt: time(m.last_saved_at) }]
          : [];
      }),
      alertsOpen: num(e.alerts_open),
    });
  }
  return out;
}

export type UnitRow = {
  unitId: string;
  scriptNumber: string;
  indexNumber: string | null;
  source: string | null;
  groupLabel: string | null;
  state: UnitState;
  onHold: boolean;
  holdReason: string | null;
  markerId: string | null;
  markerName: string | null;
  how: HoldHow | null;
  holdUntil: string | null;
  lastSavedAt: string | null;
  submittedAt: string | null;
  total: number | null;
  /** What holds a piece not yet submitted back (marking_script_blocked), or null. */
  waiting: string | null;
};

/** marking_units_list's pieces, or null when the answer is not one. */
export function parseUnits(data: unknown): UnitRow[] | null {
  const d = okAnswer(data);
  if (!d) return null;
  const out: UnitRow[] = [];
  for (const u of list(d.units)) {
    const unitId = str(u.unit_id);
    const state = pick(u.state, UNIT_STATES);
    if (!unitId || !state) continue;
    out.push({
      unitId,
      scriptNumber: str(u.script_number) ?? "",
      indexNumber: str(u.index_number),
      source: str(u.source),
      groupLabel: str(u.group_label),
      state,
      onHold: u.on_hold === true,
      holdReason: str(u.hold_reason),
      markerId: str(u.marker_id),
      markerName: str(u.marker_name),
      how: pick(u.how, HOW),
      holdUntil: time(u.hold_until),
      lastSavedAt: time(u.last_saved_at),
      submittedAt: time(u.submitted_at),
      total: typeof u.total === "number" ? u.total : null,
      waiting: str(u.waiting),
    });
  }
  return out;
}

const ALERT_KINDS = ["picture_changed", "picture_missing", "name_visible", "pages_set_aside", "pages_changed"] as const;
export type AlertKind = (typeof ALERT_KINDS)[number];
export type AlertRow = {
  id: string;
  kind: AlertKind;
  examId: string;
  examTitle: string;
  scriptId: string;
  scriptNumber: string;
  indexNumber: string | null;
  /** The page's number in the pieces, when they show it. */
  pageN: number | null;
  createdAt: string | null;
  canRelease: boolean;
  /** For an open picture_changed alert that cannot be released yet: why (marking_alert_can_release). */
  releaseBlocked: string | null;
};

/** marking_alerts_list's alerts (a kind it does not know is left out), or null when the answer is not one. */
export function parseAlerts(data: unknown): AlertRow[] | null {
  const d = okAnswer(data);
  if (!d) return null;
  const out: AlertRow[] = [];
  for (const a of list(d.alerts)) {
    const id = str(a.id);
    const kind = pick(a.kind, ALERT_KINDS);
    const examId = str(a.exam_id);
    const scriptId = str(a.script_id);
    if (!id || !kind || !examId || !scriptId) continue;
    out.push({
      id,
      kind,
      examId,
      examTitle: str(a.exam_title) ?? "",
      scriptId,
      scriptNumber: str(a.script_number) ?? "",
      indexNumber: str(a.index_number),
      pageN: typeof a.page_n === "number" ? a.page_n : null,
      createdAt: time(a.created_at),
      canRelease: a.can_release === true,
      releaseBlocked: str(a.release_blocked),
    });
  }
  return out;
}

const ALERT_KIND_TEXT: Record<AlertKind, string> = {
  picture_changed: "A page's marking picture changed, so marking of this script is on hold until it is released.",
  picture_missing: "A page has no marking picture, so marking of this script is on hold. An admin takes the script back to fix it.",
  name_visible: "A marker saw a name on a page. The script was taken back from the markers until staff hide it.",
  pages_set_aside: "A page scanned for this script was set aside, as the script is being marked.",
  pages_changed: "The pages of this script changed. Its markers are asked to check their marks and submit again.",
};

/** What an alert is about, in one or two plain sentences. */
export function alertKindText(kind: AlertKind): string {
  return ALERT_KIND_TEXT[kind];
}

/** Why Release is not offered for an alert, in one plain sentence. */
export function releaseBlockedText(reason: string | null): string {
  return releaseBlockedMessage(reason);
}

const HOLD_REASON: Record<string, string> = {
  picture_changed: "Picture changed",
  picture_missing: "Picture missing",
  name_visible: "Name visible",
  taken_back: "Taken back",
  withdrawn: "Withdrawn",
};
const UNIT_STATE: Record<UnitState, string> = { open: "Not taken", taken: "Being marked", submitted: "Submitted" };

/** A piece's state on the admin list: "On hold (Picture changed)", "Not taken", "Being marked" or "Submitted". */
export function unitStateLabel(u: Pick<UnitRow, "state" | "onHold" | "holdReason">): string {
  if (u.onHold) return u.holdReason && HOLD_REASON[u.holdReason] ? `On hold (${HOLD_REASON[u.holdReason]})` : "On hold";
  return UNIT_STATE[u.state];
}

const WAITING: Record<string, string> = {
  not_verified: "Not verified",
  marking_not_open: "Marking not open",
  marking_closed: "Marking closed",
  taken_back: "Taken back from the markers",
  late_undecided: "Late, waiting for a decision",
  home_window_open: "Home hand-in window still open",
  centre_pages_unsettled: "Centre pages still in the queue",
  pictures_updating: "Pictures being made again",
  picture_unchecked: "A marking picture waits for a staff check",
};

/** What holds a piece back, for the admin list ("" for nothing). */
export function waitingLabel(code: string | null): string {
  if (!code) return "";
  return WAITING[code] ?? "Held back";
}
