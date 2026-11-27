/** Phase 4A, Task 5: the admin's results pages. What they read from results_get and results_export, the grade boundaries
 * a person types, the "Publish at" check, the words for where results stand, and the CSV. The parsers keep only the
 * fields they know and give null for a shape they do not know, so nothing unexpected reaches the page. The database
 * checks every rule again. */

import { csvDocument } from "@/lib/csv";
import { londonLocalToUtc } from "@/lib/london-time";
import { formatLondon } from "@/lib/money";

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const num = (v: unknown): number | null => (isNum(v) ? v : null);
const count = (v: unknown): number | null => (typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null);
const str = (v: unknown): string | null => (typeof v === "string" && v.trim() !== "" ? v : null);
const time = (v: unknown): string | null => (typeof v === "string" && !Number.isNaN(Date.parse(v)) ? v : null);

export const RESULTS_STATES = ["none", "prepared", "scheduled", "published", "withdrawn"] as const;
export type ResultsState = (typeof RESULTS_STATES)[number];
export const RESULT_STATUSES = ["present", "absent", "withdrawn", "incomplete", "disqualified"] as const;
export type ResultStatus = (typeof RESULT_STATUSES)[number];
export type Sitting = "centre" | "home";

const isState = (v: unknown): v is ResultsState => RESULTS_STATES.includes(v as ResultsState);
const isStatus = (v: unknown): v is ResultStatus => RESULT_STATUSES.includes(v as ResultStatus);
const isSitting = (v: unknown): v is Sitting => v === "centre" || v === "home";

export type ResultRow = {
  bookingId: string;
  name: string | null;
  indexNumber: string | null;
  sitting: Sitting;
  status: ResultStatus;
  statusSet: boolean;
  statusReason: string | null;
  total: number | null;
  percentage: number | null;
  grade: string | null;
  rank: number | null;
  rankCohort: number | null;
  remarked: boolean;
};

export type Boundary = { grade: string; minMark: number };
export type GradeCount = { grade: string; all: number; centre: number; home: number };
export type Band = { from: number; to: number; count: number };
export type Cohort = { present: number; average: number | null; lowerQuartile: number | null; upperQuartile: number | null };
export type MissingCandidate = { bookingId: string; name: string | null; indexNumber: string | null };

export type AdminResults = {
  state: ResultsState;
  /** exam_results.version: what a sign-off sends back. */
  version: number;
  approvedAt: string | null;
  stale: boolean;
  boundaries: Boundary[];
  maxTotal: number | null;
  counts: Record<ResultStatus, number>;
  /** Null under five candidates present ("Too few candidates to compare."). */
  cohort: Cohort | null;
  bands: Band[];
  grades: GradeCount[];
  missing: MissingCandidate[];
  rows: ResultRow[];
  /** More candidates than the 2,000 rows shown. */
  more: boolean;
  publishAt: string | null;
  firstPublishedAt: string | null;
  publishedAt: string | null;
  publishFailedAt: string | null;
  publishFailedReason: string | null;
  withdrawnAt: string | null;
  withdrawReason: string | null;
};

/** One candidate's row as results_get and results_export both give it; null for a shape not known. */
function parseRow(v: unknown): ResultRow | null {
  const r = obj(v);
  if (!r || typeof r.booking_id !== "string" || !isSitting(r.sitting) || !isStatus(r.status)) return null;
  return {
    bookingId: r.booking_id,
    name: str(r.name),
    indexNumber: str(r.index_number),
    sitting: r.sitting,
    status: r.status,
    statusSet: r.status_set === true,
    statusReason: str(r.status_reason),
    total: num(r.total),
    percentage: num(r.percentage),
    grade: str(r.grade),
    rank: count(r.rank),
    rankCohort: count(r.rank_cohort),
    remarked: r.remarked === true,
  };
}

function list<T>(v: unknown, one: (x: unknown) => T | null): T[] | null {
  if (!Array.isArray(v)) return null;
  const out: T[] = [];
  for (const x of v) {
    const parsed = one(x);
    if (parsed === null) return null;
    out.push(parsed);
  }
  return out;
}

/** results_get's answer; null for a refusal or any shape that is not known. */
export function parseResults(raw: unknown): AdminResults | null {
  const d = obj(raw);
  if (!d || d.ok !== true || !isState(d.state)) return null;
  const version = count(d.version);
  const counts = obj(d.counts);
  const approval = obj(d.approval);
  if (version === null || !counts || !approval) return null;
  const rowCounts = {} as Record<ResultStatus, number>;
  for (const s of RESULT_STATUSES) {
    const n = count(counts[s]);
    if (n === null) return null;
    rowCounts[s] = n;
  }
  const rows = list(d.rows, parseRow);
  const boundaries = list(d.boundaries, (x): Boundary | null => {
    const b = obj(x);
    return b && typeof b.grade === "string" && isNum(b.min_mark) ? { grade: b.grade, minMark: b.min_mark } : null;
  });
  const bands = list(d.bands, (x): Band | null => {
    const b = obj(x);
    return b && isNum(b.from) && isNum(b.to) && count(b.count) !== null ? { from: b.from, to: b.to, count: b.count as number } : null;
  });
  const grades = list(d.grades, (x): GradeCount | null => {
    const g = obj(x);
    const [all, centre, home] = [count(g?.all), count(g?.centre), count(g?.home)];
    return g && typeof g.grade === "string" && all !== null && centre !== null && home !== null ? { grade: g.grade, all, centre, home } : null;
  });
  const missing = list(d.missing, (x): MissingCandidate | null => {
    const m = obj(x);
    return m && typeof m.booking_id === "string" ? { bookingId: m.booking_id, name: str(m.name), indexNumber: str(m.index_number) } : null;
  });
  if (!rows || !boundaries || !bands || !grades || !missing) return null;
  const c = obj(d.cohort);
  const present = count(c?.present);
  return {
    state: d.state,
    version,
    approvedAt: time(approval.approved_at),
    stale: approval.stale === true,
    boundaries,
    maxTotal: num(d.max_total),
    counts: rowCounts,
    cohort: c && present !== null ? { present, average: num(c.average), lowerQuartile: num(c.lower_quartile), upperQuartile: num(c.upper_quartile) } : null,
    bands,
    grades,
    missing,
    rows,
    more: d.more === true,
    publishAt: time(d.publish_at),
    firstPublishedAt: time(d.first_published_at),
    publishedAt: time(d.published_at),
    publishFailedAt: time(d.publish_failed_at),
    publishFailedReason: str(d.publish_failed_reason),
    withdrawnAt: time(d.withdrawn_at),
    withdrawReason: str(d.withdraw_reason),
  };
}

/** The code of a refused results_get (or any results function) answer; null when it was not a refusal. */
export function refusalCode(raw: unknown): string | null {
  const d = obj(raw);
  return d && d.ok === false ? (typeof d.code === "string" ? d.code : "internal") : null;
}

// ---------------------------------------------------------------------------------------------
// Where results stand, in words.
// ---------------------------------------------------------------------------------------------

/** "Not prepared", "Prepared", "Publishing at Sat 12 Jun 2027, 09:00 (UK time)", "Published Fri 15 Jan 2027, 12:00 (UK time)",
 * "Withdrawn". */
export function stateText(s: { state: ResultsState; publishAt: string | null; publishedAt: string | null }): string {
  switch (s.state) {
    case "none":
      return "Not prepared";
    case "prepared":
      return "Prepared";
    case "scheduled":
      return s.publishAt ? `Publishing at ${formatLondon(s.publishAt)} (UK time)` : "Publishing soon";
    case "published":
      return s.publishedAt ? `Published ${formatLondon(s.publishedAt)} (UK time)` : "Published";
    case "withdrawn":
      return "Withdrawn";
  }
}

export const STATUS_LABEL: Record<ResultStatus, string> = {
  present: "Present",
  absent: "Absent",
  withdrawn: "Withdrawn",
  incomplete: "Incomplete",
  disqualified: "Disqualified",
};

export const SITTING_LABEL: Record<Sitting, string> = { centre: "Centre", home: "Home" };

/** "1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "112th". */
export function ordinal(n: number): string {
  const last2 = n % 100;
  const last = n % 10;
  const suffix = last2 >= 11 && last2 <= 13 ? "th" : last === 1 ? "st" : last === 2 ? "nd" : last === 3 ? "rd" : "th";
  return `${n}${suffix}`;
}

// ---------------------------------------------------------------------------------------------
// Grade boundaries.
// ---------------------------------------------------------------------------------------------

export const MAX_GRADES = 15;
export type BoundaryInput = { grade: string; mark: string };

/** The boundaries a person typed, top grade first: each label 1 to 10 characters (trimmed, no two the same), each lowest
 * mark a number with at most one decimal, not below 0 and not above the paper's total, each lower than the one above;
 * at most 15. No rows is a valid set (it clears the boundaries). Anything else gives the first problem in words. */
export function validateBoundaries(
  rows: BoundaryInput[],
  maxTotal: number | null,
): { ok: true; grades: { grade: string; min_mark: number }[] } | { ok: false; message: string } {
  if (rows.length > MAX_GRADES) return { ok: false, message: `Use at most ${MAX_GRADES} grades.` };
  if (rows.length > 0 && (maxTotal === null || !(maxTotal > 0))) return { ok: false, message: "This paper has no total mark yet, so grades cannot be set." };
  const grades: { grade: string; min_mark: number }[] = [];
  const seen = new Set<string>();
  for (const [i, r] of rows.entries()) {
    const at = `Grade ${i + 1}`;
    const grade = r.grade.trim();
    if (grade.length < 1 || grade.length > 10) return { ok: false, message: `${at}: the label must be 1 to 10 characters.` };
    if (seen.has(grade.toLowerCase())) return { ok: false, message: `${at}: "${grade}" is used twice.` };
    seen.add(grade.toLowerCase());
    const text = r.mark.trim();
    if (!/^\d{1,6}(\.\d)?$/.test(text)) return { ok: false, message: `${at}: the lowest mark must be a number with at most one decimal place.` };
    const mark = Number(text);
    if (maxTotal !== null && mark > maxTotal) return { ok: false, message: `${at}: the lowest mark cannot be above the paper's total of ${maxTotal}.` };
    const above = grades[i - 1];
    if (above && mark >= above.min_mark) return { ok: false, message: `${at}: the lowest mark must be below ${above.min_mark}, the one above. List the top grade first.` };
    grades.push({ grade, min_mark: mark });
  }
  return { ok: true, grades };
}

// ---------------------------------------------------------------------------------------------
// "Publish at".
// ---------------------------------------------------------------------------------------------

const MINUTE = 60_000;
const THIRTY_DAYS = 30 * 24 * 60 * MINUTE;

/** The "Publish at" date and time, typed as UK time (Europe/London): empty means publish now (at: null). Otherwise a
 * real date and time not more than a minute in the past and not more than 30 days ahead of `nowMs`; the answer is the
 * UTC instant it means, as an ISO string. The database checks the same window again. */
export function publishAtCheck(date: string, timeOfDay: string, nowMs: number): { ok: true; at: string | null } | { ok: false; message: string } {
  if (date.trim() === "" && timeOfDay.trim() === "") return { ok: true, at: null };
  if (date.trim() === "" || timeOfDay.trim() === "") return { ok: false, message: "Give both a date and a time for Publish at, or leave both empty to publish now." };
  const at = londonLocalToUtc(date.trim(), timeOfDay.trim());
  if (!at) return { ok: false, message: "That date and time is not a real UK time. Check it and try again." };
  const ms = Date.parse(at);
  if (ms < nowMs - MINUTE) return { ok: false, message: "Publish at cannot be in the past. Use a time from now on, in UK time." };
  if (ms > nowMs + THIRTY_DAYS) return { ok: false, message: "Publish at cannot be more than 30 days ahead. Use an earlier time, in UK time." };
  return { ok: true, at };
}

// ---------------------------------------------------------------------------------------------
// The export and its CSV.
// ---------------------------------------------------------------------------------------------

export type ExportMark = { label: string; mark: number | null; notAttempted: boolean };
export type ExportRow = Pick<ResultRow, "bookingId" | "name" | "indexNumber" | "sitting" | "status" | "total" | "percentage" | "grade" | "rank"> & {
  maxTotal: number | null;
  marks: ExportMark[];
};

/** results_export's answer (every row, with the mark for each question); null for a refusal or a shape not known. */
export function parseExport(raw: unknown): { rows: ExportRow[]; filename: string } | null {
  const d = obj(raw);
  if (!d || d.ok !== true || typeof d.filename !== "string" || d.filename === "") return null;
  const rows = list(d.rows, (x): ExportRow | null => {
    const base = parseRow(x);
    const o = obj(x);
    const marks = list(o?.marks, (m): ExportMark | null => {
      const e = obj(m);
      return e && typeof e.label === "string" ? { label: e.label, mark: num(e.mark), notAttempted: e.not_attempted === true } : null;
    });
    if (!base || !marks) return null;
    const { bookingId, name, indexNumber, sitting, status, total, percentage, grade, rank } = base;
    return { bookingId, name, indexNumber, sitting, status, total, percentage, grade, rank, maxTotal: num(o?.max_total), marks };
  });
  return rows ? { rows, filename: d.filename } : null;
}

const HEADER = ["Name", "Index number", "Mode", "Status", "Total", "Maximum", "Percentage", "Grade", "Rank"];

/** The results as a CSV: a byte-order mark, CRLF lines, the header first (one column per question, in paper order), then
 * one line per candidate. A question not attempted shows "NR"; a mark not given, nothing. Every cell goes through
 * csvCell, so a name that starts with = or a tab cannot run as a formula. */
export function resultsCsv(rows: ExportRow[]): string {
  const questions: string[] = [];
  for (const r of rows) for (const m of r.marks) if (!questions.includes(m.label)) questions.push(m.label);
  const lines: (string | number)[][] = [[...HEADER, ...questions]];
  for (const r of rows) {
    const byLabel = new Map(r.marks.map((m) => [m.label, m]));
    lines.push([
      r.name ?? "",
      r.indexNumber ?? "",
      SITTING_LABEL[r.sitting],
      STATUS_LABEL[r.status],
      r.total ?? "",
      r.maxTotal ?? "",
      r.percentage ?? "",
      r.grade ?? "",
      r.rank ?? "",
      ...questions.map((q) => {
        const m = byLabel.get(q);
        return !m ? "" : m.notAttempted ? "NR" : (m.mark ?? "");
      }),
    ]);
  }
  return csvDocument(lines);
}
