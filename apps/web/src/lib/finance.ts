/** Pure helpers for the finance page: the London financial year and the date range from the address bar. */

const LONDON_DATE = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/London",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

/** Today's calendar date in London as { y, m, d }. */
export function londonDate(now: Date): { y: number; m: number; d: number } {
  const p = Object.fromEntries(LONDON_DATE.formatToParts(now).map((x) => [x.type, x.value]));
  return { y: Number(p.year), m: Number(p.month), d: Number(p.day) };
}

/** The academic (financial) year containing this instant, in London: 1 September to 31 August. */
export function financialYear(now: Date): { from: string; to: string } {
  const { y, m } = londonDate(now);
  const start = m >= 9 ? y : y - 1;
  return { from: `${start}-09-01`, to: `${start + 1}-08-31` };
}

const DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

/** "2031-10-05" if it is a real calendar date (years 2000 to 2100), else null. */
export function parseDateParam(v: string | string[] | undefined | null): string | null {
  const s = Array.isArray(v) ? v[0] : v;
  const m = typeof s === "string" ? DATE.exec(s) : null;
  if (!m) return null;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  if (y < 2000 || y > 2100) return null;
  const check = new Date(Date.UTC(y, mo - 1, d));
  if (check.getUTCFullYear() !== y || check.getUTCMonth() !== mo - 1 || check.getUTCDate() !== d) return null;
  return s as string;
}

/** The range to show: the two params when both are valid and in order, otherwise the current financial year. */
export function resolveRange(
  from: string | string[] | undefined,
  to: string | string[] | undefined,
  now: Date,
): { from: string; to: string; usedDefault: boolean; invalid: boolean } {
  const def = financialYear(now);
  const present = (Array.isArray(from) ? from[0] : from) || (Array.isArray(to) ? to[0] : to);
  const f = parseDateParam(from);
  const t = parseDateParam(to);
  if (f && t && f <= t) return { from: f, to: t, usedDefault: false, invalid: false };
  return { ...def, usedDefault: true, invalid: Boolean(present) };
}

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/** "2031-10" to "October 2031". */
export function monthLabel(ym: string): string {
  const m = /^(\d{4})-(\d{2})$/.exec(ym);
  if (!m || Number(m[2]) < 1 || Number(m[2]) > 12) return ym;
  return `${MONTHS[Number(m[2]) - 1]} ${m[1]}`;
}

/** The finance RPC answer, checked. Amounts are integer pence. */
export type MoneyLine = { taken: number; refunded: number; net: number };
export type MoneyMonth = MoneyLine & { month: string; bookings: number };
export type MoneyExam = MoneyLine & { examId: string; subject: string; title: string; startsAt: string; bookings: number };
export type MoneyTotals = { months: MoneyMonth[]; exams: MoneyExam[]; total: MoneyLine };

const isInt = (v: unknown): v is number => typeof v === "number" && Number.isInteger(v);
const isLine = (v: unknown): v is MoneyLine =>
  !!v && typeof v === "object" && isInt((v as MoneyLine).taken) && isInt((v as MoneyLine).refunded) && isInt((v as MoneyLine).net);

/** Narrows the money_totals answer; returns null for anything unexpected. */
export function readMoneyTotals(data: unknown): MoneyTotals | null {
  if (!data || typeof data !== "object") return null;
  const d = data as { months?: unknown; exams?: unknown; total?: unknown };
  if (!Array.isArray(d.months) || !Array.isArray(d.exams) || !isLine(d.total)) return null;
  const months = d.months as MoneyMonth[];
  const exams = d.exams as MoneyExam[];
  if (!months.every((m) => isLine(m) && typeof m.month === "string" && isInt(m.bookings))) return null;
  if (!exams.every((e) => isLine(e) && typeof e.examId === "string" && typeof e.title === "string" && typeof e.subject === "string" && typeof e.startsAt === "string" && isInt(e.bookings))) return null;
  return { months, exams, total: d.total };
}
