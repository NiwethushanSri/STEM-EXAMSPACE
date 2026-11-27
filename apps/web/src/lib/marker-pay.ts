/** 3B Task 12: marker pay for admins (examiner pay, not family payments). What the pages read from marker_rates_get and
 * marker_statements_get, the words and money they show, and the monthly CSV. Money is whole pence end to end; months
 * are UK calendar months ("2027-03"). The parsers keep only the fields they know: exams, question groups, kinds of
 * marking, counts, pence and the markers' names, never a script number or anything about a candidate. The database
 * checks every rule again. */

import { CSV_BOM, csvCell } from "@/lib/csv";
import { utcToLondonParts } from "@/lib/london-time";
import { formatMoney } from "@/lib/money";

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const count = (v: unknown): number | null => (typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null);
const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
const time = (v: unknown): string | null => (typeof v === "string" && !Number.isNaN(Date.parse(v)) ? v : null);

/** The highest rate per piece, in pence (£1,000). */
export const RATE_MAX = 100000;

/** The kinds of marking that are paid. */
export type PayKind = "live" | "second" | "remark";
const KIND_LABELS: Record<PayKind, string> = { live: "First marking", second: "Second marking", remark: "Re-marking" };
const isKind = (v: unknown): v is PayKind => typeof v === "string" && Object.hasOwn(KIND_LABELS, v);

/** "First marking", "Second marking" or "Re-marking". */
export function kindLabel(kind: PayKind): string {
  return KIND_LABELS[kind];
}

// ---------------------------------------------------------------------------------------------
// Money.
// ---------------------------------------------------------------------------------------------

/** Whole pence as pounds for the page: 1250 -> "£12.50", 0 -> "£0.00", 100000 -> "£1,000.00". */
export function penceToPounds(pence: number): string {
  return formatMoney(pence);
}

/** Whole pence as a plain amount for a spreadsheet: 1250 -> "12.50". */
function poundsNumber(pence: number): string {
  return `${Math.floor(pence / 100)}.${String(pence % 100).padStart(2, "0")}`;
}

/** Pounds typed by an admin to whole pence: "12.5" -> 1250, "£3" -> 300, "1,000" -> 100000. Null for anything else: a
 * fraction of a penny ("1.999"), a sign ("-1", "+3"), an empty box, thousands with a leading zero ("0,500", which is
 * a comma decimal, not £500), or anything that is not an amount. */
export function parsePounds(text: string): number | null {
  const m = /^£?\s*([1-9]\d{0,2}(?:,\d{3})+|\d+)(?:\.(\d{1,2}))?$/.exec(text.trim());
  if (!m) return null;
  const pence = Number(m[1].replace(/,/g, "")) * 100 + Number((m[2] ?? "").padEnd(2, "0"));
  return Number.isSafeInteger(pence) ? pence : null;
}

/** Every rate box of the page as whole pence from 0 to £1,000, or null when any box is not one (checked before the
 * server is asked). */
export function readRates(texts: string[]): number[] | null {
  if (texts.length === 0) return null;
  const out: number[] = [];
  for (const t of texts) {
    const p = parsePounds(t);
    if (p === null || p < 0 || p > RATE_MAX) return null;
    out.push(p);
  }
  return out;
}

/** Said when a rate box is not an amount from £0 to £1,000. */
export const RATE_PROBLEM = "Enter each rate in pounds, from £0 to £1,000, such as 12.50.";

// ---------------------------------------------------------------------------------------------
// Months (UK calendar months).
// ---------------------------------------------------------------------------------------------

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const MONTH = /^(\d{4})-(0[1-9]|1[0-2])$/;

/** A month as "2027-03". */
export function isMonth(v: unknown): v is string {
  return typeof v === "string" && MONTH.test(v);
}

/** The UK month ("2027-03") of a database date ("2027-03-01"), a month ("2027-03") or an instant (read in UK time).
 * Null for anything else. */
function ukMonth(value: string): string | null {
  const d = /^(\d{4})-(\d{2})(?:-(\d{2}))?$/.exec(value);
  if (d) return isMonth(`${d[1]}-${d[2]}`) ? `${d[1]}-${d[2]}` : null;
  if (!/^\d{4}-\d{2}-\d{2}T/.test(value) || Number.isNaN(Date.parse(value))) return null;
  return utcToLondonParts(value).date.slice(0, 7);
}

/** "March 2027" for "2027-03", "2027-03-01", or an instant in March 2027 in UK time; "" for anything else. */
export function monthLabel(month: string): string {
  const m = ukMonth(month);
  return m ? `${MONTHS[Number(m.slice(5)) - 1]} ${m.slice(0, 4)}` : "";
}

/** The month before "2027-03": "2027-02". */
function previousMonth(month: string): string {
  const y = Number(month.slice(0, 4));
  const m = Number(month.slice(5));
  return m === 1 ? `${y - 1}-12` : `${y}-${String(m - 1).padStart(2, "0")}`;
}

/** The UK month of this instant: "2026-11". */
export function currentMonth(now: string): string {
  return ukMonth(now) ?? "";
}

/** The last month that has ended in UK time: in November 2026, "2026-10". */
export function lastEndedMonth(now: string): string {
  return previousMonth(currentMonth(now));
}

/** The month picker: the month that is still running, and the 24 months that have ended, the last ended first. A month
 * asked for that is not among them (an earlier one) is added at the end. */
export function pickerMonths(now: string, selected: string): { ended: string[]; current: string } {
  const current = currentMonth(now);
  const ended: string[] = [];
  for (let m = lastEndedMonth(now); ended.length < 24; m = previousMonth(m)) ended.push(m);
  if (isMonth(selected) && selected < ended[ended.length - 1]) ended.push(selected);
  return { ended, current };
}

const UK_DATE = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", day: "numeric", month: "long", year: "numeric" });

/** An instant as a UK date: "2 April 2027". */
export function ukDate(at: string): string {
  const d = new Date(at);
  return Number.isNaN(d.getTime()) ? "" : UK_DATE.format(d);
}

// ---------------------------------------------------------------------------------------------
// What the pages read.
// ---------------------------------------------------------------------------------------------

/** An exam's pay rates (marker_rates_get): one with no group for an exam marked as whole scripts, else one per question
 * group in the paper's order; pence null where none is set. fixedPieces: the exam's pieces in fixed statements (once
 * there are any, a change needs a reason). */
export type RatesView = {
  mode: "whole" | "by_question";
  rates: { groupId: string | null; label: string | null; pence: number | null }[];
  fixedPieces: number;
};

/** marker_rates_get's answer; null when it was refused or cannot be read. */
export function parseRates(data: unknown): RatesView | null {
  const d = obj(data);
  if (!d || d.ok !== true || (d.mode !== "whole" && d.mode !== "by_question") || !Array.isArray(d.rates)) return null;
  const rates = d.rates.map(obj).filter((r): r is Obj => r !== null);
  return {
    mode: d.mode,
    rates: rates.map((r) => ({ groupId: str(r.group_id), label: str(r.group_label), pence: count(r.pence) })),
    fixedPieces: count(d.fixed_pieces) ?? 0,
  };
}

/** What the rate boxes are made from: the mode, the groups and the stored pence. When it changes (a save, then the page
 * refreshing) the boxes are made again from what is stored. */
export function ratesKey(r: RatesView): string {
  return `${r.mode}:${r.rates.map((x) => `${x.groupId ?? ""}=${x.pence ?? ""}`).join(",")}`;
}

/** The rate boxes' text for stored pence: "£12.50", or empty where no rate is set. */
export function rateTexts(pence: (number | null)[]): string[] {
  return pence.map((p) => (p === null ? "" : penceToPounds(p)));
}

/** A line of a marker's statement: one exam, question group (null: a whole script), kind and rate. ratePence and pence
 * are null while the exam has no rate. */
export type StatementLine = {
  examId: string;
  examTitle: string;
  paper: string;
  groupLabel: string | null;
  kind: PayKind;
  pieces: number;
  ratePence: number | null;
  pence: number | null;
};

/** One marker's statement for the month. fixedAt null: not fixed yet. totalPence null while any line has no rate. */
export type MarkerStatement = {
  markerId: string;
  name: string | null;
  fixedAt: string | null;
  pieces: number;
  totalPence: number | null;
  lines: StatementLine[];
};

/** An exam with payable marking and no rate. */
export type RateMissingExam = { examId: string; title: string; paper: string };

/** A month's statements (marker_statements_get). month: "2027-03". ended: the month has ended in UK time. fixed: every
 * statement with marking in it is fixed. */
export type Statements = {
  month: string;
  ended: boolean;
  fixed: boolean;
  rateMissing: RateMissingExam[];
  markers: MarkerStatement[];
};

/** The exams with no rate, as marker_statements_get (rate_missing) and a refused fix (exams) give them. */
export function parseRateMissing(v: unknown): RateMissingExam[] {
  if (!Array.isArray(v)) return [];
  return v.flatMap((x) => {
    const e = obj(x);
    const id = e ? str(e.exam_id) : null;
    return e && id ? [{ examId: id, title: str(e.exam_title) ?? "Removed exam", paper: str(e.paper) ?? "" }] : [];
  });
}

const absent = (v: unknown) => v === null || v === undefined;
const sum = (xs: number[]) => xs.reduce((n, x) => n + x, 0);

/** One line, or null when it cannot be read: an exam, a kind that is paid and a count of scripts; with a rate, the
 * amount is the rate times the scripts; with none, there is no amount either. */
function parseLine(v: unknown): StatementLine | null {
  const l = obj(v);
  const examId = l ? str(l.exam_id) : null;
  const pieces = l ? count(l.pieces) : null;
  if (!l || !examId || pieces === null || !isKind(l.kind)) return null;
  const rated = !absent(l.rate_pence);
  const ratePence = rated ? count(l.rate_pence) : null;
  const pence = rated ? count(l.pence) : null;
  if (rated ? ratePence === null || pence === null || pence !== ratePence * pieces : !absent(l.pence)) return null;
  return {
    examId,
    examTitle: str(l.exam_title) ?? "Removed exam",
    paper: str(l.paper) ?? "",
    groupLabel: str(l.group_label),
    kind: l.kind,
    pieces,
    ratePence,
    pence,
  };
}

/** One marker's statement, or null when it cannot be read: every line must be readable and add up to the marker's
 * scripts and total; the total is there exactly when every line has an amount; a fixed time must be a time. */
function parseMarker(v: unknown): MarkerStatement | null {
  const m = obj(v);
  const markerId = m ? str(m.marker_id) : null;
  if (!m || !markerId || !Array.isArray(m.lines)) return null;
  const lines: StatementLine[] = [];
  for (const x of m.lines) {
    const l = parseLine(x);
    if (!l) return null;
    lines.push(l);
  }
  const pieces = count(m.pieces);
  if (pieces === null || pieces !== sum(lines.map((l) => l.pieces))) return null;
  const known = lines.every((l) => l.pence !== null);
  const totalPence = known ? count(m.total_pence) : null;
  if (known ? totalPence === null || totalPence !== sum(lines.map((l) => l.pence ?? 0)) : !absent(m.total_pence)) return null;
  const fixedAt = time(m.fixed_at);
  if (fixedAt === null && !absent(m.fixed_at)) return null;
  return { markerId, name: str(m.name), fixedAt, pieces, totalPence, lines };
}

/** marker_statements_get's answer, or the code it was refused with; null for an answer it cannot read, which includes
 * one with any marker or line it cannot read (so no figures are shown that do not add up). */
export function parseStatements(data: unknown): { ok: true; statements: Statements } | { ok: false; code: string } | null {
  const d = obj(data);
  if (!d) return null;
  if (d.ok !== true) return { ok: false, code: typeof d.code === "string" ? d.code : "internal" };
  const month = typeof d.month === "string" ? ukMonth(d.month) : null;
  if (!month || !Array.isArray(d.markers)) return null;
  const markers: MarkerStatement[] = [];
  for (const x of d.markers) {
    const m = parseMarker(x);
    if (!m) return null;
    markers.push(m);
  }
  return {
    ok: true,
    statements: { month, ended: d.ended === true, fixed: d.fixed === true, rateMissing: parseRateMissing(d.rate_missing), markers },
  };
}

/** A marker's name, or what stands for it when the account has none. */
export function markerName(name: string | null): string {
  return name ?? "Unnamed marker";
}

/** The exam as a line shows it: "Maths (Paper 1)". */
export function examName(title: string, paper: string): string {
  return paper ? `${title} (${paper})` : title;
}

/** Whether a marker's statement is fixed, in the page's words. */
export function fixedText(fixedAt: string | null): string {
  return fixedAt ? `Fixed on ${ukDate(fixedAt)}` : "Not fixed yet. These figures can still change.";
}

/** A line's question group: its label, or "Whole script". */
export function groupText(label: string | null): string {
  return label ?? "Whole script";
}

// ---------------------------------------------------------------------------------------------
// The CSV.
// ---------------------------------------------------------------------------------------------

/** Kept here so marker-pay callers and tests still import it from this file. */
export { csvCell };

const CSV_HEADER = "Month,Marker,Exam,Paper,Question group,Kind,Scripts,Rate (£),Amount (£),Fixed";

/** A month's statements as a CSV: a UTF-8 byte-order mark, CRLF lines, the header, one row per line and one "Total" row
 * per marker. Amounts are plain pounds ("12.50"); a line with no rate says "Rate not set" and has no amount, and so has
 * the total of its marker. Fixed: the UK date the marker's statement was fixed, or "Not fixed". */
export function statementCsv(s: Statements): string {
  const month = monthLabel(s.month);
  const rows: (string | number)[][] = [];
  for (const m of s.markers) {
    const name = markerName(m.name);
    const fixed = m.fixedAt ? ukDate(m.fixedAt) : "Not fixed";
    for (const l of m.lines) {
      rows.push([
        month,
        name,
        l.examTitle,
        l.paper,
        groupText(l.groupLabel),
        kindLabel(l.kind),
        l.pieces,
        l.ratePence === null ? "Rate not set" : poundsNumber(l.ratePence),
        l.pence === null ? "" : poundsNumber(l.pence),
        fixed,
      ]);
    }
    rows.push([month, name, "Total", "", "", "", m.pieces, "", m.totalPence === null ? "" : poundsNumber(m.totalPence), fixed]);
  }
  return `${CSV_BOM}${[CSV_HEADER, ...rows.map((r) => r.map(csvCell).join(","))].join("\r\n")}\r\n`;
}
