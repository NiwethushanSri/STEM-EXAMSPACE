/** What `booking_paper_state` tells a family about a home booking's paper, and the words they see for it. */
export type BookingPaperState = {
  sitting: "centre" | "home";
  status: "centre" | "missing" | "not_yet" | "held" | "open" | "closed";
  release_at: string | null;
  /** The database clock that decided the status (older servers may leave it out). */
  server_now?: string | null;
  last_download: { at: string; by_name: string | null } | null;
  corrected: boolean;
  inserts: { id: string; title: string }[];
};

const TIME = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
const DAY = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", weekday: "long", day: "numeric", month: "long" });
const YMD = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", year: "numeric", month: "2-digit", day: "2-digit" });

const parts = (f: Intl.DateTimeFormat, d: Date) => Object.fromEntries(f.formatToParts(d).map((p) => [p.type, p.value]));
/** "09:50" in London time. */
const clock = (d: Date) => {
  const p = parts(TIME, d);
  return `${p.hour}:${p.minute}`;
};
/** "Saturday 5 June" in London time. */
const dayDate = (d: Date) => {
  const p = parts(DAY, d);
  return `${p.weekday} ${p.day} ${p.month}`;
};

export const PAPER_TEXT = {
  centre: "Your booking is for the centre; your paper is handed out in the exam room",
  missing: "Your paper is not ready yet. The institution has been told.",
  held: "The paper is paused by the institution. Please wait.",
  corrected: "A corrected paper is available. Download it again.",
  ready: "Your paper is ready to download.",
  closed: "Paper downloads are closed for this booking.",
  failure: "The paper could not be prepared. Please try again.",
  unpaid: "Pay for this booking to get the paper.",
} as const;

export function paperMessage(state: BookingPaperState, now: Date): { text: string; action: "download" | "none" } {
  void now; // the server's clock decided the status; the time only matters to the caller's wording
  switch (state.status) {
    case "centre":
      return { text: PAPER_TEXT.centre, action: "none" };
    case "missing":
      return { text: PAPER_TEXT.missing, action: "none" };
    case "held":
      return { text: PAPER_TEXT.held, action: "none" };
    case "not_yet": {
      const at = state.release_at ? new Date(state.release_at) : null;
      if (!at || Number.isNaN(at.getTime())) return { text: PAPER_TEXT.missing, action: "none" };
      return { text: `Your paper will be ready at ${clock(at)} on ${dayDate(at)}`, action: "none" };
    }
    case "open":
      return { text: state.corrected ? PAPER_TEXT.corrected : PAPER_TEXT.ready, action: "download" };
    case "closed":
    default:
      return { text: PAPER_TEXT.closed, action: "none" };
  }
}

/** "Downloaded at 09:52 by Pat Tester" (the day is added when it was not today). Empty when nothing was downloaded. */
export function downloadedLine(last: BookingPaperState["last_download"], now: Date): string {
  if (!last) return "";
  const at = new Date(last.at);
  if (Number.isNaN(at.getTime())) return "";
  const sameDay = YMD.format(at) === YMD.format(now);
  const when = sameDay ? clock(at) : `${clock(at)} on ${dayDate(at)}`;
  return `Downloaded at ${when}${last.by_name ? ` by ${last.by_name}` : ""}`;
}

/** How often the page looks again while the paper is close to release, held or missing. */
export const RECHECK_MS = 25_000;
/** Within this long of the release the page looks again every RECHECK_MS. */
export const NEAR_RELEASE_MS = 15 * 60_000;
/** Longest wait before looking again, so a long timer never overflows. */
export const MAX_WAIT_MS = 10 * 60_000;

/** How far the device clock is behind the database clock, in ms (0 when unknown). `sentAt`/`receivedAt` are the
 * device times around the request, so the server time is compared with their midpoint. */
export function clockSkewMs(state: BookingPaperState, sentAt: number, receivedAt: number): number {
  const server = state.server_now ? Date.parse(state.server_now) : NaN;
  return Number.isNaN(server) ? 0 : server - (sentAt + receivedAt) / 2;
}

/**
 * When to ask the server again, in ms from now, or null for never. The server decides the status; the page only
 * chooses when to ask. Before the release: every RECHECK_MS from 15 minutes before it, plus once just after it
 * (by the server's clock); further out, wake up when the 15 minutes start. Held or missing: every RECHECK_MS, so
 * a resume or a late upload shows without reloading. Open, closed or centre: never.
 */
export function nextCheckMs(state: BookingPaperState, deviceNow: number, skewMs: number): number | null {
  if (state.status === "held" || state.status === "missing") return RECHECK_MS;
  if (state.status !== "not_yet") return null;
  const at = state.release_at ? Date.parse(state.release_at) : NaN;
  if (Number.isNaN(at)) return RECHECK_MS;
  const until = at - (deviceNow + skewMs);
  if (until > NEAR_RELEASE_MS) return Math.min(until - NEAR_RELEASE_MS + 1000, MAX_WAIT_MS);
  if (until > 0) return Math.max(Math.min(until + 1500, RECHECK_MS), 1500);
  // The release has passed by the server's clock but the answer was still "not yet": ask again soon, then less
  // often (an exam taken back to draft stays "not yet").
  return until > -60_000 ? 5_000 : RECHECK_MS;
}
