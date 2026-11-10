/** An exam can no longer be booked once its booking deadline or its start time has passed. */
export function isClosed(exam: { booking_deadline: string; starts_at: string }, now: Date): boolean {
  return now >= new Date(exam.booking_deadline) || now >= new Date(exam.starts_at);
}
