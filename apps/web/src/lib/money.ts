const GBP = new Intl.NumberFormat("en-GB", { style: "currency", currency: "GBP" });

/** Integer pence to display text: 1500 -> "£15.00", 0 -> "Free". */
export function formatPence(p: number): string {
  if (p === 0) return "Free";
  return GBP.format(p / 100);
}

const LONDON = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/London",
  weekday: "short",
  day: "numeric",
  month: "short",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

/** A timestamp in UK local time (BST or GMT as in force on that date): "Sat 12 Jun 2027, 09:00". */
export function formatLondon(ts: string): string {
  const d = new Date(ts);
  if (Number.isNaN(d.getTime())) return "";
  const p = Object.fromEntries(LONDON.formatToParts(d).map((x) => [x.type, x.value]));
  return `${p.weekday} ${p.day} ${p.month} ${p.year}, ${p.hour}:${p.minute}`;
}

/**
 * Pounds typed into a form ("15", "15.5", "0.99") to integer pence. Returns null for anything else:
 * negatives, more than 2 decimal places, signs, symbols, exponents or blanks.
 */
export function poundsToPence(input: string): number | null {
  const m = /^(\d{1,7})(?:\.(\d{1,2}))?$/.exec(input.trim());
  if (!m) return null;
  return Number(m[1]) * 100 + Number((m[2] ?? "").padEnd(2, "0"));
}

/** Integer pence to the number for a price input: 1500 -> "15.00". */
export function penceToInput(p: number): string {
  return (p / 100).toFixed(2);
}

/** Money amounts in tables and totals: like formatPence, but zero is "£0.00" rather than "Free". */
export function formatMoney(p: number): string {
  return p === 0 ? "£0.00" : formatPence(p);
}
