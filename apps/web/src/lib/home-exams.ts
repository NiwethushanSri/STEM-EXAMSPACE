import { isClosed } from "./exam-state";
import { SITTING_LABEL } from "./exam-form";
import { utcToLondonParts } from "./london-time";
import { formatPence } from "./money";

/** One row of the public `exams_public` view, as the home page reads it. */
export type PublicExam = {
  id: string;
  subject: string;
  title: string;
  paper: string;
  format: "in_person" | "online" | "both";
  starts_at: string;
  duration_minutes: number;
  price_pence: number;
  booking_deadline: string;
  /** Seats left across the current centres; null when the exam is sat at home only. */
  seats_left: number | null;
  /** The current centres by venue name (rooms are never public), each with its seats left. */
  centres: PublicCentre[];
};

export type PublicCentre = { id: string; venue: string; seats_left: number };

export const PUBLIC_EXAM_COLUMNS =
  "id, subject, title, paper, format, starts_at, duration_minutes, price_pence, booking_deadline, seats_left, centres";

/** How a paper stands for a family looking at it now. */
export type PaperState = "open" | "few" | "full" | "closed";

/** At or below this many seats a paper shows as nearly full. */
export const FEW_SEATS = 5;

export function paperState(exam: PublicExam, now: Date): PaperState {
  if (isClosed(exam, now)) return "closed";
  // Home sittings have no limit, so an exam that is sat at home (alone or as a choice) is never full.
  if (exam.format !== "in_person" || exam.seats_left == null) return "open";
  if (exam.seats_left <= 0) return "full";
  if (exam.seats_left <= FEW_SEATS) return "few";
  return "open";
}

export const STATE_LABEL: Record<PaperState, string> = {
  open: "Booking open",
  few: "Few seats left",
  full: "Fully booked",
  closed: "Booking closed",
};

/** The papers still to come, soonest first. */
export function upcoming(exams: PublicExam[], now: Date): PublicExam[] {
  return exams
    .filter((e) => new Date(e.starts_at) > now)
    .sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at));
}

/** The paper the home page leads with: the soonest one still bookable, else the soonest upcoming one. */
export function pickNextPaper(exams: PublicExam[], now: Date): PublicExam | null {
  const list = upcoming(exams, now);
  const bookable = list.find((e) => {
    const s = paperState(e, now);
    return s === "open" || s === "few";
  });
  return bookable ?? list[0] ?? null;
}

/** Subject colour follows the logo emblem: maths green (pi), sciences teal (atom), computing orange (code). */
export type SubjectGroup = "maths" | "science" | "computing" | "other";

export function subjectGroup(subject: string): SubjectGroup {
  const s = subject.toLowerCase();
  if (s.includes("math")) return "maths";
  if (/physics|chemistry|biology|science/.test(s) && !/computer/.test(s)) return "science";
  if (/computer|computing/.test(s)) return "computing";
  return "other";
}

const DAY_MS = 86_400_000;

/** Whole UK calendar days from now until the paper's date: 0 on the day itself, 1 the day before. */
export function daysUntil(startsAt: string, now: Date): number {
  const today = utcToLondonParts(now.toISOString()).date;
  const day = utcToLondonParts(startsAt).date;
  return Math.round((Date.parse(`${day}T00:00:00Z`) - Date.parse(`${today}T00:00:00Z`)) / DAY_MS);
}

export function countdownText(days: number): string {
  if (days <= 0) return "Today";
  if (days === 1) return "Tomorrow";
  return `In ${days} days`;
}

/** Where the paper is sat, in a few words: the sitting, then the venue of each centre. */
export function placeText(exam: Pick<PublicExam, "format" | "centres">): string {
  const label = SITTING_LABEL[exam.format];
  if (exam.format === "online") return label;
  const venues = [...new Set(exam.centres.map((c) => c.venue))];
  return venues.length ? `${label}: ${venues.join(", ")}` : label;
}

/** The seats line of a paper, or null when there is nothing to count (home only). */
export function seatLine(exam: Pick<PublicExam, "format" | "seats_left">): string | null {
  if (exam.format === "online" || exam.seats_left == null) return null;
  const n = Math.max(0, exam.seats_left);
  if (exam.format === "both") return n === 0 ? "Centre full" : `${n} seat${n === 1 ? "" : "s"} left at the centre`;
  return `${n} seat${n === 1 ? "" : "s"} left`;
}

const LONG = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/London",
  weekday: "long",
  day: "numeric",
  month: "long",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});
const SHORT = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", weekday: "short", day: "numeric", month: "short" });

export type LondonDate = { weekday: string; day: string; month: string; year: string; time: string; short: string };

/** An instant as UK date pieces for display. */
export function londonDate(iso: string): LondonDate {
  const d = new Date(iso);
  const p = Object.fromEntries(LONG.formatToParts(d).map((x) => [x.type, x.value]));
  return {
    weekday: p.weekday,
    day: p.day,
    month: p.month,
    year: p.year,
    time: `${p.hour}:${p.minute}`,
    short: SHORT.format(d).replace(",", ""),
  };
}

/** The UK clock time a paper finishes. */
export function endTime(startsAt: string, minutes: number): string {
  return londonDate(new Date(Date.parse(startsAt) + minutes * 60_000).toISOString()).time;
}

/** "1 h 30 min", "45 min", "2 h". */
export function durationText(minutes: number): string {
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (!h) return `${m} min`;
  return m ? `${h} h ${m} min` : `${h} h`;
}

export type Level = "GCSE" | "A level" | "Other";

/** The qualification, read from the exam's title ("GCSE Maths", "A level Physics", "AS Chemistry"). */
export function levelOf(title: string): Level {
  if (/\bgcse\b/i.test(title)) return "GCSE";
  if (/\ba[\s-]?level\b|\bas\b/i.test(title)) return "A level";
  return "Other";
}

/** Everything a paper card shows, worked out on the server so times are always UK time. */
export type PaperCardData = {
  id: string;
  title: string;
  paper: string;
  subject: string;
  group: SubjectGroup;
  level: Level;
  date: string;
  time: string;
  place: string;
  price: string;
  state: PaperState;
  seatsLeft: number;
  /** "3 seats left", "Centre full", or null for a home-only paper. */
  seatLine: string | null;
};

export function toCardData(exam: PublicExam, now: Date): PaperCardData {
  const start = londonDate(exam.starts_at);
  return {
    id: exam.id,
    title: exam.title,
    paper: exam.paper,
    subject: exam.subject,
    group: subjectGroup(exam.subject),
    level: levelOf(exam.title),
    date: `${start.weekday} ${start.day} ${start.month}`,
    time: `${start.time}–${endTime(exam.starts_at, exam.duration_minutes)} · ${durationText(exam.duration_minutes)}`,
    place: placeText(exam),
    price: formatPence(exam.price_pence),
    state: paperState(exam, now),
    seatsLeft: Math.max(0, exam.seats_left ?? 0),
    seatLine: seatLine(exam),
  };
}
