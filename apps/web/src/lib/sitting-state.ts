/** What `booking_sitting_state` tells a family about a home sitting, and the words they see for it. */
export type SittingPhase = "before_start" | "sitting" | "upload_open" | "late_window" | "closed";

export type SittingState = {
  phase: SittingPhase;
  /** The database clock that decided the phase. */
  server_now: string;
  starts_at: string;
  finish_at: string;
  on_time_until: string;
  late_until: string;
  /** Null: the exam has none of its own and the institution's default shows. */
  rules: string | null;
  materials: string | null;
  acknowledged: { as_role: "parent" | "student"; at: string; by_name: string | null } | null;
  /** Who may acknowledge for the signed-in person: a parent, a student with no linked parent, or nobody. */
  ack_as: "parent" | "student" | null;
  has_parent: boolean;
  script: { number: string; state: string; late: boolean } | null;
  submission: { id: string; seq: number; state: string; late: boolean } | null;
};

export const PRINT_AT_ACTUAL_SIZE = "Print at actual size (100%), not 'Fit to page'.";

/**
 * Shown when an exam has no home rules or materials of its own. One text for the whole institution: a default per
 * subject comes with Phase 1B's subject management.
 */
export const DEFAULT_HOME_RULES = [
  "Sit the exam in a quiet room, with an adult supervising you.",
  "Start and stop at the times shown on this page. Do not read the paper before the start.",
  "Do not use notes, books, the internet, a phone or anyone's help unless the allowed materials say so.",
  "Write your answers on the printed paper, in dark ink or pencil, and keep every page.",
  PRINT_AT_ACTUAL_SIZE,
].join("\n");

export const DEFAULT_ALLOWED_MATERIALS = "Pens, pencils, a ruler and a calculator if the subject allows one. No notes, books, phone or internet.";

export const SITTING_TEXT = {
  earlyWarning: "The paper is available 10 minutes before the start so you can print it. Please do not read it before the start.",
  parentAck: "I will supervise this exam at home and follow the rules",
  studentRule: "A student with no linked parent must sit the exam under an adult's supervision.",
  studentAck: "I will sit this exam under an adult's supervision",
  parentOnly: "Your parent or guardian confirms the supervision for you.",
  failure: "The sitting details could not be loaded. Please try again.",
  ackFailure: "That could not be saved. Please try again.",
} as const;

/** How far the device clock is behind the database clock, in ms (0 when unknown). The server time is compared with the midpoint of the request. */
export function sittingSkewMs(state: Pick<SittingState, "server_now">, sentAt: number, receivedAt: number): number {
  const server = state.server_now ? Date.parse(state.server_now) : NaN;
  return Number.isNaN(server) ? 0 : server - (sentAt + receivedAt) / 2;
}

/**
 * The text for the screen-reader live region: the phase and, once given, that supervision is confirmed. It changes
 * only when the phase or the acknowledgement does, never with the ticking countdown.
 */
export function sittingAnnouncement(phase: SittingPhase, acknowledged: boolean): string {
  const title = {
    before_start: "Your exam has not started.",
    sitting: "Your exam is now under way.",
    upload_open: "The exam has finished. You can now upload your answers.",
    late_window: "The on-time upload deadline has passed. Uploads now are marked late.",
    closed: "Uploads are closed.",
  }[phase];
  return acknowledged ? `${title} Supervision confirmed.` : title;
}

const DAY_MS = 86_400_000;

/** "1:30:00" (hours without a leading zero, minutes and seconds with); a day or more reads "3 days". */
function clockText(ms: number): string {
  const total = Math.max(0, Math.ceil(ms / 1000));
  if (ms >= DAY_MS) {
    const days = Math.floor(ms / DAY_MS);
    return `${days} day${days === 1 ? "" : "s"}`;
  }
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

/**
 * The phase now and its words. `now` is the device clock in ms; `skewMs` (from sittingSkewMs) corrects it to the
 * database clock. The phase follows the times, so the screen moves on by itself; a closed answer from the server
 * (a cancelled exam) stays closed.
 */
export function sittingPhaseText(
  state: SittingState,
  now: number,
  skewMs: number,
): { phase: SittingPhase; title: string; countdown: string } {
  const t = now + skewMs;
  const starts = Date.parse(state.starts_at);
  const finish = Date.parse(state.finish_at);
  const onTime = Date.parse(state.on_time_until);
  const late = Date.parse(state.late_until);
  let phase: SittingPhase;
  if (state.phase === "closed" || [starts, finish, onTime, late].some(Number.isNaN)) phase = "closed";
  else if (t < starts) phase = "before_start";
  else if (t < finish) phase = "sitting";
  else if (t < onTime) phase = "upload_open";
  else if (t < late) phase = "late_window";
  else phase = "closed";

  switch (phase) {
    case "before_start":
      return { phase, title: "Your exam has not started", countdown: `Starts in ${clockText(starts - t)}` };
    case "sitting":
      return { phase, title: "Your exam is under way", countdown: `${clockText(finish - t)} left` };
    case "upload_open":
      return { phase, title: "Upload your answers", countdown: `${clockText(onTime - t)} left to upload on time` };
    case "late_window":
      return {
        phase,
        title: "Upload your answers: now late",
        countdown: `Uploads now are marked late. ${clockText(late - t)} left to upload at all`,
      };
    default:
      return { phase: "closed", title: "Uploads are closed", countdown: "" };
  }
}
