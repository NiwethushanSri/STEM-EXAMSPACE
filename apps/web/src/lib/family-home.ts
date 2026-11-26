import type { BookingStatus } from "@/components/bookings/status";

/** The part of a bookings row (the My bookings query) that a family home needs. */
export type FamilyBookingRow = {
  id: string;
  status: BookingStatus;
  student_id: string;
  sitting: "centre" | "home";
  exam: { title: string; starts_at: string } | null;
};

export type HomeExam = {
  bookingId: string;
  /** A parent sees the child's first name; a student sees null. */
  childName: string | null;
  examTitle: string;
  startsAt: string;
  sitting: "centre" | "home";
  status: BookingStatus;
};

/** Bookings that no longer mean a place at an exam. */
const LEFT_OUT: readonly BookingStatus[] = ["cancelled", "expired", "refunded"];

/**
 * Splits a family's bookings into upcoming and past by the exam's start against `now` (the server's time).
 * Upcoming is soonest first, past is newest first. `firstNames` (student id to first name) is given for a parent.
 */
export function familyHome(
  rows: readonly FamilyBookingRow[],
  now: Date,
  firstNames?: ReadonlyMap<string, string>,
): { upcoming: HomeExam[]; past: HomeExam[] } {
  const exams: HomeExam[] = [];
  for (const r of rows) {
    if (!r.exam || LEFT_OUT.includes(r.status)) continue;
    exams.push({
      bookingId: r.id,
      childName: firstNames ? (firstNames.get(r.student_id) ?? "Your child") : null,
      examTitle: r.exam.title,
      startsAt: r.exam.starts_at,
      sitting: r.sitting,
      status: r.status,
    });
  }
  const time = (e: HomeExam) => new Date(e.startsAt).getTime();
  return {
    upcoming: exams.filter((e) => time(e) > now.getTime()).sort((a, b) => time(a) - time(b)),
    past: exams.filter((e) => time(e) <= now.getTime()).sort((a, b) => time(b) - time(a)),
  };
}
