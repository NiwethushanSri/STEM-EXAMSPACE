import { londonLocalToUtc, utcToLondonParts } from "./london-time";
import { poundsToPence } from "./money";
import { isUuid } from "./uuid";

export type ExamFormat = "in_person" | "online" | "both";

/** How an exam is sat, in the words used on every screen. */
export const SITTING_LABEL: Record<ExamFormat, string> = {
  in_person: "At the centre",
  online: "At home",
  both: "At the centre or at home",
};
export const SITTING_MODE_LABEL: Record<"centre" | "home", string> = {
  centre: "At the centre",
  home: "At home",
};

/** One place the exam is sat: a venue and room with its own seat limit. `id` is set for a centre already saved. */
export type CentreValues = { id?: string; venueId: string; room: string; seatLimit: number };

const MAX_CENTRES = 20;
export const HOME_RULES_MAX = 2000;
export const MATERIALS_MAX = 500;

/** The values save_exam takes, read from the exam form. Times are already UTC instants. */
export type ExamValues = {
  id: string | null;
  subjectId: number;
  title: string;
  paper: string;
  format: ExamFormat;
  /** Empty for a home-only exam. */
  centres: CentreValues[];
  startsAt: string;
  durationMinutes: number;
  /** Null when the form has no price field (teachers). */
  pricePence: number | null;
  bookingDeadline: string;
  /** Rules and allowed materials for sitting at home; empty means the institution default shows. Saved by set_exam_home_rules. */
  homeRules: string;
  allowedMaterials: string;
};

/**
 * The UTC instant for a date and time typed in UK time. When the form says the inputs were left alone
 * ("keep" holds the stored instant) and that instant still reads as exactly this date and time, the
 * stored instant is kept: a time in the repeated October hour could otherwise move by an hour.
 */
function resolveInstant(date: string, time: string, keep: string): string | null {
  if (keep) {
    const ms = Date.parse(keep);
    if (!Number.isNaN(ms)) {
      const iso = new Date(ms).toISOString();
      const p = utcToLondonParts(iso);
      if (p.date === date && p.time === time) return iso;
    }
  }
  return londonLocalToUtc(date, time);
}

const WHOLE = /^\d{1,6}$/;

/**
 * Reads and checks the exam form (field values as strings). Returns the first problem as a sentence
 * for the person filling it in; the database repeats every rule, this just gives readable messages.
 */
export function parseExamForm(
  raw: Record<string, string>,
  opts: { withPrice: boolean },
): { ok: true; value: ExamValues } | { ok: false; error: string } {
  if (!raw || typeof raw !== "object") return { ok: false, error: "Please check the details you entered." };
  // Anything that is not text (for example an uploaded file) is not a valid answer.
  for (const v of Object.values(raw)) {
    if (typeof v !== "string") return { ok: false, error: "Please check the details you entered." };
  }
  const get = (k: string) => (raw[k] ?? "").trim();
  const fail = (error: string) => ({ ok: false as const, error });

  const id = get("id");
  if (id && !isUuid(id)) return fail("This exam could not be found. Refresh the page.");

  if (!WHOLE.test(get("subject"))) return fail("Choose a subject.");
  const subjectId = Number(get("subject"));

  const title = get("title");
  if (!title) return fail("Enter a title.");
  if (title.length > 120) return fail("The title can be at most 120 characters.");
  const paper = get("paper");
  if (paper.length > 80) return fail("The paper can be at most 80 characters.");

  const format = get("format");
  if (format !== "in_person" && format !== "online" && format !== "both") return fail("Choose where the exam is sat.");
  const centres: CentreValues[] = [];
  if (format !== "online") {
    // Centre rows are numbered from 0 in the form, but a removed row can leave a gap: read what is there, in order.
    const indexes = [
      ...new Set(
        Object.keys(raw)
          .map((k) => /^centre\.(\d{1,3})\./.exec(k)?.[1])
          .filter((v): v is string => v !== undefined)
          .map(Number),
      ),
    ].sort((a, b) => a - b);
    if (indexes.length === 0) return fail("Add at least one centre.");
    if (indexes.length > MAX_CENTRES) return fail(`An exam can have at most ${MAX_CENTRES} centres.`);
    const seen = new Set<string>();
    for (const [n, i] of indexes.entries()) {
      const where = `Centre ${n + 1}`;
      const venue = get(`centre.${i}.venue`);
      const room = get(`centre.${i}.room`);
      const seats = get(`centre.${i}.seats`);
      const cid = get(`centre.${i}.id`);
      if (!isUuid(venue)) return fail(`${where}: choose a venue.`);
      if (!room) return fail(`${where}: choose a room.`);
      if (cid && !isUuid(cid)) return fail("This exam could not be found. Refresh the page.");
      if (!WHOLE.test(seats)) return fail(`${where}: enter the seat limit as a whole number.`);
      const seatLimit = Number(seats);
      if (seatLimit < 1 || seatLimit > 1000) return fail(`${where}: the seat limit must be between 1 and 1000.`);
      const key = `${venue}
${room}`;
      if (seen.has(key)) return fail(`${where}: this room is already used by another centre of this exam.`);
      seen.add(key);
      centres.push({ ...(cid ? { id: cid } : {}), venueId: venue, room, seatLimit });
    }
  }

  if (!get("startDate") || !get("startTime")) return fail("Choose the exam date and time.");
  const startsAt = resolveInstant(get("startDate"), get("startTime"), get("startsAtKeep"));
  if (!startsAt) return fail("The exam start is not a valid UK time. If the clocks change that night, pick a time that exists.");
  if (!get("deadlineDate") || !get("deadlineTime")) return fail("Choose the booking deadline date and time.");
  const bookingDeadline = resolveInstant(get("deadlineDate"), get("deadlineTime"), get("deadlineKeep"));
  if (!bookingDeadline) return fail("The booking deadline is not a valid UK time. If the clocks change that night, pick a time that exists.");
  if (Date.parse(bookingDeadline) > Date.parse(startsAt)) return fail("The booking deadline must be no later than the exam start.");

  if (!WHOLE.test(get("duration"))) return fail("Enter the duration in whole minutes.");
  const durationMinutes = Number(get("duration"));
  if (durationMinutes < 15 || durationMinutes > 600) return fail("The duration must be between 15 and 600 minutes.");

  const homeRules = get("homeRules");
  if (homeRules.length > HOME_RULES_MAX) return fail(`The home exam rules can be at most ${HOME_RULES_MAX} characters.`);
  const allowedMaterials = get("allowedMaterials");
  if (allowedMaterials.length > MATERIALS_MAX) return fail(`The allowed materials can be at most ${MATERIALS_MAX} characters.`);

  let pricePence: number | null = null;
  if (opts.withPrice) {
    pricePence = poundsToPence(get("price"));
    if (pricePence === null) return fail("Enter the price in pounds, like 15 or 15.50: no negatives and at most 2 decimal places. Use 0 for a free exam.");
    if (pricePence > 100000) return fail("The price cannot be more than £1,000.");
  }

  return {
    ok: true,
    value: {
      id: id || null,
      subjectId,
      title,
      paper,
      format,
      centres,
      startsAt,
      durationMinutes,
      pricePence,
      bookingDeadline,
      homeRules,
      allowedMaterials,
    },
  };
}

/** Rooms typed one per line into a list, blanks dropped (a comma is part of a room name). */
export function parseRooms(raw: string): string[] {
  return raw
    .split(/\r?\n/)
    .map((r) => r.trim())
    .filter(Boolean);
}
