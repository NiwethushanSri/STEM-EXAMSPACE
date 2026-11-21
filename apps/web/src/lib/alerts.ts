// Notices, exam calendar and alerts for students and parents.
// Everything is kept in this browser (localStorage) until a real backend exists.
// Read these functions only in effects or event handlers, never while rendering on the server.
// The staff alerts from the scripts dashboard (at the end) are pure and come from the database instead.

import { formatLondon } from "@/lib/money";
import { children, notices as defaultNotices, timetable as defaultTimetable } from "@/lib/site-data";

export type Notice = {
  id: number;
  title: string;
  date: string;
  type: "Latest notice" | "Special notice";
  body: string;
};

export type Exam = {
  date: string;
  subject: string;
  time: string;
  type: string;
};

export type Alert = {
  id: string;
  childId: string;
  audience: "student" | "parent";
  kind: "notice" | "exam-update" | "reminder" | "report";
  title: string;
  body: string;
  createdAt: string;
};

// The child whose student and parent views are shown in this mock.
export const DEMO_CHILD_ID = "amara-perera";

const KEYS = {
  notices: "stem-notices",
  timetable: "stem-timetable",
  alerts: "stem-alerts",
};

const DAY_MS = 24 * 60 * 60 * 1000;
const REMINDER_DAYS = 3;

function read<T>(key: string, fallback: T): T {
  if (typeof window === "undefined") return fallback;
  try {
    const raw = window.localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as T) : fallback;
  } catch {
    return fallback;
  }
}

function write<T>(key: string, value: T) {
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // Storage full or blocked: the change stays on screen only.
  }
}

// "14 Nov 2026", the same style the site uses everywhere.
export function displayDate(d: Date): string {
  return d.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
}

export function getNotices(): Notice[] {
  return read<Notice[]>(KEYS.notices, defaultNotices as Notice[]);
}

export function getTimetable(): Exam[] {
  return read<Exam[]>(KEYS.timetable, defaultTimetable as Exam[]);
}

export function getAlerts(): Alert[] {
  return read<Alert[]>(KEYS.alerts, []);
}

// Exams that have not happened yet, earliest first.
export function upcomingExams(list: Exam[], now: Date = new Date()): Exam[] {
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  return list
    .map((exam) => ({ exam, time: new Date(exam.date).getTime() }))
    .filter((x) => !Number.isNaN(x.time) && x.time >= today)
    .sort((a, b) => a.time - b.time)
    .map((x) => x.exam);
}

// One alert for each student and each parent of every child.
function notifyEveryone(kind: Alert["kind"], id: string, title: string, body: string): number {
  const now = new Date().toISOString();
  const fresh: Alert[] = children.flatMap((child) =>
    (["student", "parent"] as const).map((audience) => ({
      id: `${id}-${child.id}-${audience}`,
      childId: child.id,
      audience,
      kind,
      title,
      body,
      createdAt: now,
    })),
  );
  write(KEYS.alerts, [...fresh, ...getAlerts()]);
  return children.length;
}

// Admin publishes a notice: it is saved and every student and parent is alerted.
export function publishNotice(input: { title: string; body: string; type: Notice["type"] }): number {
  const notice: Notice = {
    id: Date.now(),
    title: input.title,
    body: input.body,
    type: input.type,
    date: displayDate(new Date()),
  };
  write(KEYS.notices, [notice, ...getNotices()]);
  return notifyEveryone("notice", `notice-${notice.id}`, notice.title, notice.body);
}

function reportId(childId: string, termName: string): string {
  return `report-${termName.replace(/\s+/g, "-")}-${childId}`;
}

export function hasReportSent(childId: string, termName: string): boolean {
  return getAlerts().some((a) => a.id === reportId(childId, termName));
}

// Student sends a term report: the parent gets one alert. Returns false if it was already sent.
export function sendReportToParent(childId: string, termName: string, body: string): boolean {
  if (hasReportSent(childId, termName)) return false;
  const alert: Alert = {
    id: reportId(childId, termName),
    childId,
    audience: "parent",
    kind: "report",
    title: `${termName} progress report`,
    body,
    createdAt: new Date().toISOString(),
  };
  write(KEYS.alerts, [alert, ...getAlerts()]);
  return true;
}

// Sends a reminder once for each exam that is 0 to 3 days away.
// There is no server timer yet, so this runs when a student or parent opens their dashboard.
export function runReminders(now: Date = new Date()): number {
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const existing = getAlerts();
  const seen = new Set(existing.map((a) => a.id));
  const fresh: Alert[] = [];
  const createdAt = now.toISOString();

  for (const exam of getTimetable()) {
    const examDay = new Date(exam.date);
    if (Number.isNaN(examDay.getTime())) continue;
    const days = Math.round((examDay.getTime() - today.getTime()) / DAY_MS);
    if (days < 0 || days > REMINDER_DAYS) continue;
    const when = days === 0 ? "today" : days === 1 ? "tomorrow" : `in ${days} days`;

    for (const child of children) {
      for (const audience of ["student", "parent"] as const) {
        const id = `reminder-${exam.subject}-${exam.date}-${child.id}-${audience}`;
        if (seen.has(id)) continue;
        seen.add(id);
        fresh.push({
          id,
          childId: child.id,
          audience,
          kind: "reminder",
          title: `${exam.subject} exam ${when}`,
          body: `${exam.time}, ${exam.type}. Check the timetable and bring your index number card.`,
          createdAt,
        });
      }
    }
  }

  if (fresh.length > 0) write(KEYS.alerts, [...fresh, ...existing]);
  return fresh.length;
}

// ---------------------------------------------------------------------------------------------
// Staff alerts from the scripts dashboard (public.scripts_dashboard), shown on the admin home. Pure: the page reads
// the dashboard on the server and shows these.

/** One exam of the last 14 days: scripts expected (paid home bookings and centre candidates marked present or late),
 * received, verified (or further on), needing attention, and handed in late. */
export type ScriptsDashboardExam = {
  id: string;
  title: string;
  paper: string | null;
  startsAt: string;
  expected: number;
  received: number;
  verified: number;
  needsAttention: number;
  late: number;
  /** Home bookings whose family uploaded files but never pressed Submit (counted once the exam has finished). */
  unsubmitted: number;
};

/** A centre whose sheets were counted but which has no "scanned" custody record by 09:00 the day after the exam. */
export type CentreNotScanned = {
  examId: string;
  title: string;
  paper: string | null;
  centreId: string;
  venue: string;
  room: string;
  counted: number;
  scannedBy: string;
};

export type ScriptsDashboard = {
  exams: ScriptsDashboardExam[];
  /** Home bookings, of any exam, with uploaded files that were never submitted. */
  unsubmittedDrafts: number;
  openExceptions: number;
  failedJobs: number;
  /** How long the oldest file due to be processed has waited (a file the server stopped part-way through included),
   * or null when none waits. */
  oldestQueuedMinutes: number | null;
  /** Files the server stopped part-way through: still "running", their lock not renewed for 15 minutes. */
  stuckJobs: number;
  centresNotScanned: CentreNotScanned[];
};

export type StaffAlert = { id: string; tone: "red" | "amber"; text: string; href: string | null };

/** The processing server takes a file every few seconds and a file takes minutes at most: a file due this long ago
 * means the server is stopped or stuck. */
export const QUEUE_STUCK_MINUTES = 15;

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const counted = (v: unknown): number => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : 0);
const text = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

function dashboardExam(x: unknown): ScriptsDashboardExam | null {
  if (!isRecord(x) || !isRecord(x.exam)) return null;
  const id = text(x.exam.id);
  const title = text(x.exam.title);
  const startsAt = text(x.exam.starts_at);
  if (!id || !title || !startsAt) return null;
  return {
    id,
    title,
    paper: text(x.exam.paper),
    startsAt,
    expected: counted(x.expected),
    received: counted(x.received),
    verified: counted(x.verified),
    needsAttention: counted(x.needs_attention),
    late: counted(x.late),
    unsubmitted: counted(x.unsubmitted),
  };
}

function centreNotScanned(x: unknown): CentreNotScanned | null {
  if (!isRecord(x)) return null;
  const examId = text(x.exam_id);
  const title = text(x.title);
  const centreId = text(x.centre_id);
  const venue = text(x.venue);
  const room = text(x.room);
  const scannedBy = text(x.scanned_by);
  if (!examId || !title || !centreId || !venue || !room || !scannedBy) return null;
  return { examId, title, paper: text(x.paper), centreId, venue, room, counted: counted(x.counted), scannedBy };
}

/** scripts_dashboard's answer, or null for a refusal or a broken answer. Malformed rows are left out. */
export function parseScriptsDashboard(data: unknown): ScriptsDashboard | null {
  if (!isRecord(data) || data.ok !== true) return null;
  const minutes = data.oldest_queued_minutes;
  return {
    exams: (Array.isArray(data.exams) ? data.exams : []).map(dashboardExam).filter((e): e is ScriptsDashboardExam => e !== null),
    unsubmittedDrafts: counted(data.unsubmitted_drafts),
    openExceptions: counted(data.open_exceptions),
    failedJobs: counted(data.failed_jobs),
    oldestQueuedMinutes: typeof minutes === "number" && Number.isInteger(minutes) && minutes >= 0 ? minutes : null,
    stuckJobs: counted(data.stuck_jobs),
    centresNotScanned: (Array.isArray(data.centres_without_scanned_custody) ? data.centres_without_scanned_custody : [])
      .map(centreNotScanned)
      .filter((c): c is CentreNotScanned => c !== null),
  };
}

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** What staff should act on, the most urgent first: a stopped processing server, files that could not be processed,
 * families who uploaded pages but never submitted them, centres whose collected sheets were not scanned by 09:00 the next day, and problems in the exception queue. */
export function scriptsDashboardAlerts(d: ScriptsDashboard): StaffAlert[] {
  const out: StaffAlert[] = [];
  const waited = d.oldestQueuedMinutes ?? 0;
  if (d.stuckJobs > 0) {
    out.push({
      id: "queue",
      tone: "red",
      text:
        `${plural(d.stuckJobs, "file", "files")} stopped part-way through processing, and files have waited ${waited} minutes. ` +
        "Check that the processing server is running.",
      href: null,
    });
  } else if (waited >= QUEUE_STUCK_MINUTES) {
    out.push({
      id: "queue",
      tone: "red",
      text: `Files have waited ${waited} minutes to be processed. Check that the processing server is running.`,
      href: null,
    });
  }
  if (d.failedJobs > 0) {
    out.push({
      id: "failed",
      tone: "red",
      text: `${plural(d.failedJobs, "file", "files")} could not be processed. ${d.failedJobs === 1 ? "It is" : "They are"} in the exception queue.`,
      href: "/admin/scripts/exceptions?kind=processing_failed",
    });
  }
  if (d.unsubmittedDrafts > 0) {
    out.push({
      id: "unsent",
      tone: "red",
      text: `${plural(d.unsubmittedDrafts, "family", "families")} uploaded pages but did not press Submit. Their answers were not handed in.`,
      href: "/admin/scripts/unsent",
    });
  }
  for (const c of d.centresNotScanned) {
    out.push({
      id: `custody-${c.examId}-${c.centreId}`,
      tone: "amber",
      text:
        `${c.title}${c.paper ? ` (${c.paper})` : ""}, ${c.venue}, ${c.room}: sheets were collected for ${plural(c.counted, "candidate", "candidates")} ` +
        `but no scan is recorded. It was due by ${formatLondon(c.scannedBy)}.`,
      href: `/admin/exams/${c.examId}`,
    });
  }
  if (d.openExceptions > 0) {
    out.push({
      id: "open",
      tone: "amber",
      text: `${plural(d.openExceptions, "problem is", "problems are")} waiting in the exception queue.`,
      href: "/admin/scripts/exceptions",
    });
  }
  return out;
}
