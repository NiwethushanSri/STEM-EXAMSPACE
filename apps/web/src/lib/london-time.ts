const PARTS = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/London",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
});

function partsAt(ms: number): Record<string, number> {
  const out: Record<string, number> = {};
  for (const p of PARTS.formatToParts(new Date(ms))) if (p.type !== "literal") out[p.type] = Number(p.value);
  return out;
}

/** Minutes London is ahead of UTC at this instant: 0 in GMT, 60 in BST. */
function offsetMinutes(ms: number): number {
  const p = partsAt(ms);
  const localAsUtc = Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second);
  return Math.round((localAsUtc - Math.floor(ms / 1000) * 1000) / 60000);
}

const DATE = /^(\d{4})-(\d{2})-(\d{2})$/;
const TIME = /^(\d{2}):(\d{2})$/;

/**
 * A date ("2027-06-12") and time ("09:00") read as UK wall-clock time become the UTC instant they mean,
 * as an ISO string. Returns null for input that is not a real date and time, and for a time that does
 * not exist because the clocks go forward (01:30 on the last Sunday of March). A time that happens
 * twice when the clocks go back (01:30 on the last Sunday of October) means the first one, in BST.
 */
export function londonLocalToUtc(date: string, time: string): string | null {
  const d = DATE.exec(date);
  const t = TIME.exec(time);
  if (!d || !t) return null;
  const [y, mo, da, h, mi] = [d[1], d[2], d[3], t[1], t[2]].map(Number);
  if (h > 23 || mi > 59) return null;
  const wall = Date.UTC(y, mo - 1, da, h, mi);
  const check = new Date(wall);
  if (check.getUTCFullYear() !== y || check.getUTCMonth() !== mo - 1 || check.getUTCDate() !== da) return null;
  // London is only ever UTC+0 or UTC+1. Keep each guess whose own offset agrees with it; the BST guess comes first.
  for (const off of [60, 0]) {
    const instant = wall - off * 60000;
    if (offsetMinutes(instant) === off) return new Date(instant).toISOString();
  }
  return null;
}

/** An instant as UK wall-clock date and time for the form inputs: { date: "2027-06-12", time: "09:00" }. */
export function utcToLondonParts(iso: string): { date: string; time: string } {
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return { date: "", time: "" };
  const p = partsAt(ms);
  const two = (n: number) => String(n).padStart(2, "0");
  return { date: `${p.year}-${two(p.month)}-${two(p.day)}`, time: `${two(p.hour)}:${two(p.minute)}` };
}
