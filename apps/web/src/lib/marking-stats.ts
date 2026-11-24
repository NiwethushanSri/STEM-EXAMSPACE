/** Marker statistics per exam (marking_stats), for the admin's statistics page and the lead marker's Statistics tab:
 * what they read, and the words the table uses. The parser keeps only the fields it knows, so nothing else reaches a
 * page: the function gives markers' names and figures per piece, never a candidate's name, index or script number. */
import { isUuid } from "@/lib/uuid";

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const count = (v: unknown): number => (typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : 0);

export const STATS_NOTES = ["fast", "full_marks", "mean_apart"] as const;
export type StatsNoteCode = (typeof STATS_NOTES)[number];
const isNote = (v: unknown): v is StatsNoteCode => STATS_NOTES.includes(v as StatsNoteCode);

const NOTE_TEXT: Record<StatsNoteCode, string> = {
  fast: "Much faster than usual for this exam.",
  full_marks: "Many scripts at full marks.",
  mean_apart: "Average mark is far from the other markers'.",
};

/** A note under a marker's row, headed "Worth a look"; "" for a code this page does not know. */
export function statsNote(code: string): string {
  return isNote(code) ? NOTE_TEXT[code] : "";
}

/** A time in whole seconds: "45 s", "4 min 10 s", "4 min", "1 h 2 min"; "—" for none. */
export function secondsText(s: number | null): string {
  if (s === null || !Number.isFinite(s) || s < 0) return "—";
  const t = Math.round(s);
  if (t < 60) return `${t} s`;
  const h = Math.floor(t / 3600);
  const min = Math.floor((t % 3600) / 60);
  const sec = t % 60;
  if (h > 0) return min > 0 ? `${h} h ${min} min` : `${h} h`;
  return sec > 0 ? `${min} min ${sec} s` : `${min} min`;
}

const points = (n: number) => `${Math.round(Math.abs(n) * 10) / 10}`;

/** How a marker's average mark stands beside the other markers' of the same questions, in percentage points. */
export function differenceText(d: number | null): string {
  if (d === null) return "";
  if (d === 0) return "The same as the others";
  const n = points(d);
  return `${n} ${n === "1" ? "point" : "points"} ${d > 0 ? "above" : "below"} the others`;
}

/** "18 of 20 within tolerance"; "—" when nothing was compared. */
export function agreementText(within: number, done: number): string {
  return done > 0 ? `${within} of ${done} within tolerance` : "—";
}

/** "72.5%"; "—" for none. */
export function percentText(p: number | null): string {
  return p === null ? "—" : `${Math.round(p * 10) / 10}%`;
}

export type Agreement = { done: number; within: number };
export type MarkerStat = {
  markerId: string;
  name: string;
  pieces: number;
  meanPercent: number | null;
  cohortMeanPercent: number | null;
  difference: number | null;
  second: { compared: number; within: number; meanGap: number | null };
  seeds: Agreement;
  practice: Agreement;
  medianSeconds: number | null;
  sentBack: number;
  notes: StatsNoteCode[];
};
export type ExamStats = {
  tolerancePercent: number;
  exam: { pieces: number; meanPercent: number | null; medianSeconds: number | null };
  markers: MarkerStat[];
};

const agreement = (v: unknown): Agreement => {
  const a = obj(v);
  return { done: count(a?.done), within: count(a?.within) };
};

/** marking_stats's answer, or the code it was refused with; null for an answer it cannot read. A marker without a
 * valid id is left out; one with no name is "Marker" and the start of their id, as the other lists say it; notes it does
 * not know are dropped. */
export function parseStats(data: unknown): { ok: true; stats: ExamStats } | { ok: false; code: string } | null {
  const d = obj(data);
  if (!d) return null;
  if (d.ok !== true) return { ok: false, code: typeof d.code === "string" ? d.code : "internal" };
  if (!Array.isArray(d.markers)) return null;
  const exam = obj(d.exam);
  const markers = d.markers.flatMap((v): MarkerStat[] => {
    const m = obj(v);
    if (!m || !isUuid(m.marker_id)) return [];
    const second = obj(m.second);
    return [
      {
        markerId: m.marker_id,
        name: typeof m.name === "string" && m.name.trim() !== "" ? m.name : `Marker ${m.marker_id.slice(0, 8)}`,
        pieces: count(m.pieces),
        meanPercent: num(m.mean_percent),
        cohortMeanPercent: num(m.cohort_mean_percent),
        difference: num(m.difference),
        second: { compared: count(second?.compared), within: count(second?.within), meanGap: num(second?.mean_gap) },
        seeds: agreement(m.seeds),
        practice: agreement(m.practice),
        medianSeconds: num(m.median_seconds),
        sentBack: count(m.sent_back),
        notes: Array.isArray(m.notes) ? m.notes.filter(isNote) : [],
      },
    ];
  });
  return {
    ok: true,
    stats: {
      tolerancePercent: count(d.tolerance_percent),
      exam: { pieces: count(exam?.pieces), meanPercent: num(exam?.mean_percent), medianSeconds: num(exam?.median_seconds) },
      markers,
    },
  };
}
