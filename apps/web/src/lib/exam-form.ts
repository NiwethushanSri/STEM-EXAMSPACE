import { londonLocalToUtc } from "./london-time";
import { poundsToPence } from "./money";

/** The values save_exam takes, read from the exam form. Times are already UTC instants. */
export type ExamValues = {
  id: string | null;
  subjectId: number;
  title: string;
  paper: string;
  format: "in_person" | "online";
  venueId: string | null;
  room: string | null;
  startsAt: string;
  durationMinutes: number;
  seatLimit: number;
  /** Null when the form has no price field (teachers). */
  pricePence: number | null;
  bookingDeadline: string;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const isUuid = (v: unknown): v is string => typeof v === "string" && UUID.test(v);

const WHOLE = /^\d{1,6}$/;

/**
 * Reads and checks the exam form (field values as strings). Returns the first problem as a sentence
 * for the person filling it in; the database repeats every rule, this just gives readable messages.
 */
export function parseExamForm(
  raw: Record<string, string>,
  opts: { withPrice: boolean },
): { ok: true; value: ExamValues } | { ok: false; error: string } {
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
  if (format !== "in_person" && format !== "online") return fail("Choose in person or online.");
  let venueId: string | null = null;
  let room: string | null = null;
  if (format === "in_person") {
    if (!isUuid(get("venue"))) return fail("Choose a venue for an in-person exam.");
    if (!get("room")) return fail("Choose a room for an in-person exam.");
    venueId = get("venue");
    room = get("room");
  }

  if (!get("startDate") || !get("startTime")) return fail("Choose the exam date and time.");
  const startsAt = londonLocalToUtc(get("startDate"), get("startTime"));
  if (!startsAt) return fail("The exam start is not a valid UK time. If the clocks change that night, pick a time that exists.");
  if (!get("deadlineDate") || !get("deadlineTime")) return fail("Choose the booking deadline date and time.");
  const bookingDeadline = londonLocalToUtc(get("deadlineDate"), get("deadlineTime"));
  if (!bookingDeadline) return fail("The booking deadline is not a valid UK time. If the clocks change that night, pick a time that exists.");
  if (Date.parse(bookingDeadline) > Date.parse(startsAt)) return fail("The booking deadline must be no later than the exam start.");

  if (!WHOLE.test(get("duration"))) return fail("Enter the duration in whole minutes.");
  const durationMinutes = Number(get("duration"));
  if (durationMinutes < 15 || durationMinutes > 600) return fail("The duration must be between 15 and 600 minutes.");

  if (!WHOLE.test(get("seats"))) return fail("Enter the seat limit as a whole number.");
  const seatLimit = Number(get("seats"));
  if (seatLimit < 1 || seatLimit > 1000) return fail("The seat limit must be between 1 and 1000.");

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
      venueId,
      room,
      startsAt,
      durationMinutes,
      seatLimit,
      pricePence,
      bookingDeadline,
    },
  };
}

/** Rooms typed one per line (or separated by commas) into a list, blanks dropped. */
export function parseRooms(raw: string): string[] {
  return raw
    .split(/[\r\n,]+/)
    .map((r) => r.trim())
    .filter(Boolean);
}
