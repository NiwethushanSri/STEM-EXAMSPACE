import "server-only";
import { createClient } from "@/lib/supabase/server";
import { isClosed } from "@/lib/exam-state";
import { requireStaff } from "@/lib/staff-gate";

export type SubjectOption = { id: number; name: string };
export type VenueOption = { id: string; name: string; rooms: string[]; active: boolean };
export type ExamStatus = "draft" | "published" | "cancelled" | "completed";

export type ExamRow = {
  id: string;
  title: string;
  paper: string;
  subjectId: number;
  subject: string;
  format: "in_person" | "online";
  venueId: string | null;
  venue: string | null;
  room: string | null;
  startsAt: string;
  durationMinutes: number;
  seatLimit: number;
  /** Admin screens only; the teacher loader never selects the price. */
  pricePence: number | null;
  priceConfirmed: boolean;
  bookingDeadline: string;
  status: ExamStatus;
  /** Seats taken: bookings awaiting payment, paid or cancel-requested. */
  seatsSold: number;
  /** Money kept: amount minus refunds over paid and part-refunded bookings. */
  moneyPence: number;
  /** Bookings flagged for a refund (the exam was cancelled), with who and how much. */
  refundsDue: { bookingId: string; student: string; pence: number }[];
  /** Published, but past its booking deadline or start time. */
  bookingClosed: boolean;
  /** Any booking at all, so the screen can say why a price is locked. */
  hasBookings: boolean;
};

type Embedded<T> = T | T[] | null;
const one = <T,>(v: Embedded<T>): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));

type ExamQueryRow = {
  id: string;
  title: string;
  paper: string;
  subject_id: number;
  format: "in_person" | "online";
  venue_id: string | null;
  room: string | null;
  starts_at: string;
  duration_minutes: number;
  seat_limit: number;
  price_pence?: number;
  price_confirmed?: boolean;
  booking_deadline: string;
  status: ExamStatus;
  subject: Embedded<{ name: string }>;
  venue: Embedded<{ name: string }>;
};

type BookingQueryRow = {
  id: string;
  exam_id: string;
  status: string;
  amount_pence: number;
  refunded_pence: number;
  refund_due: boolean;
  student: Embedded<{ first_name: string; last_name: string }>;
};

const SEAT_STATUSES = ["awaiting_payment", "paid", "cancel_requested"];
const PAGE = 1000;

/** Every booking of these exams, read a page at a time because the API caps one response. */
async function loadBookings(examIds: string[]): Promise<BookingQueryRow[]> {
  if (examIds.length === 0) return [];
  const supabase = await createClient();
  const out: BookingQueryRow[] = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await supabase
      .from("bookings")
      .select("id, exam_id, status, amount_pence, refunded_pence, refund_due, student:profiles!bookings_student_id_fkey(first_name, last_name)")
      .in("exam_id", examIds)
      .order("created_at", { ascending: true })
      .order("id", { ascending: true })
      .range(from, from + PAGE - 1);
    if (error) throw new Error("bookings could not be loaded");
    const rows = (data ?? []) as unknown as BookingQueryRow[];
    out.push(...rows);
    if (rows.length < PAGE) return out;
  }
}

function toRows(exams: ExamQueryRow[], bookings: BookingQueryRow[]): ExamRow[] {
  const byExam = new Map<string, BookingQueryRow[]>();
  for (const b of bookings) byExam.set(b.exam_id, [...(byExam.get(b.exam_id) ?? []), b]);
  return exams.map((e) => {
    const bs = byExam.get(e.id) ?? [];
    const cancelled = e.status === "cancelled";
    return {
      id: e.id,
      title: e.title,
      paper: e.paper,
      subjectId: e.subject_id,
      subject: one(e.subject)?.name ?? "",
      format: e.format,
      venueId: e.venue_id,
      venue: one(e.venue)?.name ?? null,
      room: e.room,
      startsAt: e.starts_at,
      durationMinutes: e.duration_minutes,
      seatLimit: e.seat_limit,
      pricePence: e.price_pence ?? null,
      priceConfirmed: e.price_confirmed ?? false,
      bookingDeadline: e.booking_deadline,
      status: e.status,
      // A cancelled exam releases its seats.
      seatsSold: cancelled ? 0 : bs.filter((b) => SEAT_STATUSES.includes(b.status)).length,
      moneyPence: bs
        .filter((b) => b.status === "paid" || b.status === "part_refunded")
        .reduce((sum, b) => sum + b.amount_pence - b.refunded_pence, 0),
      refundsDue: cancelled
        ? bs
            .filter((b) => b.refund_due && b.amount_pence > b.refunded_pence)
            .map((b) => {
              const s = one(b.student);
              return {
                bookingId: b.id,
                student: s ? `${s.first_name} ${s.last_name}`.trim() : "Student removed",
                pence: b.amount_pence - b.refunded_pence,
              };
            })
        : [],
      bookingClosed: e.status === "published" && isClosed({ booking_deadline: e.booking_deadline, starts_at: e.starts_at }, new Date()),
      hasBookings: bs.length > 0,
    };
  });
}

async function loadSubjects(): Promise<SubjectOption[]> {
  const supabase = await createClient();
  const { data } = await supabase.from("subjects").select("id, name").eq("active", true).order("name");
  return (data ?? []).map((s) => ({ id: s.id, name: s.name }));
}

export async function loadVenues(): Promise<VenueOption[]> {
  const supabase = await createClient();
  const { data } = await supabase.from("venues").select("id, name, rooms, active").order("name");
  return (data ?? []).map((v) => ({ id: v.id, name: v.name, rooms: v.rooms ?? [], active: v.active }));
}

const ADMIN_COLUMNS =
  "id, title, paper, subject_id, format, venue_id, room, starts_at, duration_minutes, seat_limit, price_pence, price_confirmed, booking_deadline, status, subject:subjects(name), venue:venues(name)";
const TEACHER_COLUMNS =
  "id, title, paper, subject_id, format, venue_id, room, starts_at, duration_minutes, seat_limit, booking_deadline, status, subject:subjects(name), venue:venues(name)";

/** The admin exams screen: every exam, its seats and money, plus the subjects and venues the form needs. */
export async function loadAdminExams() {
  await requireStaff(["admin", "owner"]);
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("exams")
    .select(ADMIN_COLUMNS)
    .order("starts_at", { ascending: false })
    .limit(500);
  if (error) throw new Error("exams could not be loaded");
  const exams = (data ?? []) as unknown as ExamQueryRow[];
  const [bookings, subjects, venues] = await Promise.all([
    loadBookings(exams.map((e) => e.id)),
    loadSubjects(),
    loadVenues(),
  ]);
  return { exams: toRows(exams, bookings), subjects, venues };
}

/**
 * The teacher exams screen: exams in the teacher's own subjects only. The price is never selected and
 * no bookings are read (a teacher sees no money and no student names here).
 */
export async function loadTeacherExams() {
  const me = await requireStaff(["teacher"]);
  const supabase = await createClient();
  const { data: links } = await supabase.from("teacher_subjects").select("subject_id").eq("teacher_id", me.id);
  const ids = (links ?? []).map((l) => l.subject_id);
  if (ids.length === 0) return { exams: [] as ExamRow[], subjects: [] as SubjectOption[], venues: [] as VenueOption[] };
  const [{ data, error }, allSubjects, venues] = await Promise.all([
    supabase
      .from("exams")
      .select(TEACHER_COLUMNS)
      .in("subject_id", ids)
      .order("starts_at", { ascending: false })
      .limit(500),
    loadSubjects(),
    loadVenues(),
  ]);
  if (error) throw new Error("exams could not be loaded");
  const exams = toRows((data ?? []) as unknown as ExamQueryRow[], []);
  return { exams, subjects: allSubjects.filter((s) => ids.includes(s.id)), venues: venues.filter((v) => v.active) };
}

/** The admin venues screen. */
export async function loadAdminVenues() {
  await requireStaff(["admin", "owner"]);
  return loadVenues();
}
