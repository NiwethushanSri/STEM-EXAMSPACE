// Notices, exam calendar and alerts for students and parents.
// Everything is kept in this browser (localStorage) until a real backend exists.
// Read these functions only in effects or event handlers, never while rendering on the server.

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
