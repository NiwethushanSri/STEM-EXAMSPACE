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
