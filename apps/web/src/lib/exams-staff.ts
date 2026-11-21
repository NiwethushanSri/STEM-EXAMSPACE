import "server-only";
import { chunk } from "@/lib/chunk";
import { createClient } from "@/lib/supabase/server";
import { examMoney } from "@/lib/exam-money";
import { isClosed } from "@/lib/exam-state";
import { requireStaff } from "@/lib/staff-gate";
import type { ExamFormat } from "@/lib/exam-form";

export type SubjectOption = { id: number; name: string };
export type VenueOption = { id: string; name: string; rooms: string[]; active: boolean };
export type ExamStatus = "draft" | "published" | "cancelled" | "completed";

/** One current centre of an exam (archived centres are never listed). `seatsSold` is 0 where bookings are not read (teachers). */
export type ExamCentre = { id: string; venueId: string; venue: string; room: string; seatLimit: number; seatsSold: number };

export type ExamRow = {
  id: string;
  title: string;
  paper: string;
  subjectId: number;
  subject: string;
  format: ExamFormat;
  centres: ExamCentre[];
  startsAt: string;
  durationMinutes: number;
  /** Admin screens only; the teacher loader never selects the price. */
  pricePence: number | null;
  priceConfirmed: boolean;
  bookingDeadline: string;
  /** Rules and allowed materials for the home sitting; empty text means the institution default shows. */
  homeRules: string;
  allowedMaterials: string;
  status: ExamStatus;
  /** Seats taken: bookings awaiting payment, paid or cancel-requested, at a centre or at home. */
  seatsSold: number;
  /** The part of `seatsSold` sitting at home (no seat limit). */
  homeBooked: number;
  /** Net taken: amount minus refunds over every booking with paid_at set (matches Finance). */
  moneyPence: number;
  /** Bookings flagged for a refund (the exam was cancelled), with who and how much. */
  refundsDue: { bookingId: string; student: string; pence: number }[];
  /** Published, but past its booking deadline or start time. */
  bookingClosed: boolean;
  /** Any booking at all, so the screen can say why a price is locked. */
  hasBookings: boolean;
  /** Admin screens only: the exam has a current question paper. Teachers never see papers, so this is false for them. */
  hasPaper: boolean;
  /** When families can first download the paper (admin screens only; a teacher row repeats the start time). */
  releaseAt: string;
};

type Embedded<T> = T | T[] | null;
const one = <T,>(v: Embedded<T>): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));

type ExamQueryRow = {
  id: string;
  title: string;
  paper: string;
  subject_id: number;
  format: ExamFormat;
  starts_at: string;
  duration_minutes: number;
  price_pence?: number;
  price_confirmed?: boolean;
  booking_deadline: string;
  home_rules?: string | null;
  allowed_materials?: string | null;
  status: ExamStatus;
  release_minutes_before?: number;
  released_early_at?: string | null;
  subject: Embedded<{ name: string }>;
  centres: Embedded<CentreQueryRow>[] | null;
};

type CentreQueryRow = {
  id: string;
  venue_id: string;
  room: string;
  seat_limit: number;
  removed_at: string | null;
  created_at: string;
  venue: Embedded<{ name: string }>;
};

type BookingQueryRow = {
  id: string;
  exam_id: string;
  status: string;
  centre_id: string | null;
  sitting: "centre" | "home";
  amount_pence: number;
  refunded_pence: number;
  refund_due: boolean;
  paid_at: string | null;
};

const SEAT_STATUSES = ["awaiting_payment", "paid", "cancel_requested"];
const PAGE = 1000;
/** The admin list shows this many exams, newest first. */
export const EXAM_CAP = 500;

const ID_BATCH = 100;
const BOOKING_COLUMNS = "id, exam_id, status, centre_id, sitting, amount_pence, refunded_pence, refund_due, paid_at";

/** Every booking of these exams (no names), in batches of exam ids and a page at a time: the API caps one response and one URL. */
async function loadBookings(examIds: string[]): Promise<BookingQueryRow[]> {
  const supabase = await createClient();
  const out: BookingQueryRow[] = [];
  for (const ids of chunk(examIds, ID_BATCH)) {
    for (let from = 0; ; from += PAGE) {
      const { data, error } = await supabase
        .from("bookings")
        .select(BOOKING_COLUMNS)
        .in("exam_id", ids)
        .order("created_at", { ascending: true })
        .order("id", { ascending: true })
        .range(from, from + PAGE - 1);
      if (error) throw new Error("bookings could not be loaded");
      const rows = (data ?? []) as unknown as BookingQueryRow[];
      out.push(...rows);
      if (rows.length < PAGE) break;
    }
  }
  return out;
}

/** Student names for the bookings flagged for refund only (a second, narrow query), keyed by booking id. */
async function loadRefundNames(examIds: string[]): Promise<Map<string, string>> {
  const supabase = await createClient();
  const names = new Map<string, string>();
  for (const ids of chunk(examIds, ID_BATCH)) {
    for (let from = 0; ; from += PAGE) {
      const { data, error } = await supabase
        .from("bookings")
        .select("id, student:profiles!bookings_student_id_fkey(first_name, last_name)")
        .in("exam_id", ids)
        .eq("refund_due", true)
        .order("id", { ascending: true })
        .range(from, from + PAGE - 1);
      if (error) throw new Error("refund names could not be loaded");
      const rows = (data ?? []) as unknown as { id: string; student: Embedded<{ first_name: string; last_name: string }> }[];
      for (const r of rows) {
        const st = one(r.student);
        names.set(r.id, st ? `${st.first_name} ${st.last_name}`.trim() : "Student removed");
      }
      if (rows.length < PAGE) break;
    }
  }
  return names;
}

/** The exam's current centres, by venue then room. Archived centres (removed_at set) stay readable through RLS but are never shown. */
export function centresOf(e: { centres: Embedded<CentreQueryRow>[] | null }): CentreQueryRow[] {
  return (e.centres ?? [])
    .map((c) => one(c))
    .filter((c): c is CentreQueryRow => c !== null && c.removed_at === null)
    .sort((a, b) => (one(a.venue)?.name ?? "").localeCompare(one(b.venue)?.name ?? "") || a.room.localeCompare(b.room) || a.id.localeCompare(b.id));
}

function toRows(exams: ExamQueryRow[], bookings: BookingQueryRow[], names: Map<string, string> = new Map(), withPaper: Set<string> = new Set()): ExamRow[] {
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
      centres: centresOf(e).map((c) => ({
        id: c.id,
        venueId: c.venue_id,
        venue: one(c.venue)?.name ?? "",
        room: c.room,
        seatLimit: c.seat_limit,
        // A cancelled exam releases its seats.
        seatsSold: cancelled ? 0 : bs.filter((b) => b.centre_id === c.id && SEAT_STATUSES.includes(b.status)).length,
      })),
      startsAt: e.starts_at,
      durationMinutes: e.duration_minutes,
      pricePence: e.price_pence ?? null,
      priceConfirmed: e.price_confirmed ?? false,
      bookingDeadline: e.booking_deadline,
      homeRules: e.home_rules ?? "",
      allowedMaterials: e.allowed_materials ?? "",
      status: e.status,
      // A cancelled exam releases its seats.
      seatsSold: cancelled ? 0 : bs.filter((b) => SEAT_STATUSES.includes(b.status)).length,
      homeBooked: cancelled ? 0 : bs.filter((b) => b.sitting === "home" && SEAT_STATUSES.includes(b.status)).length,
      moneyPence: examMoney(bs).net,
      refundsDue: cancelled
        ? bs
            .filter((b) => b.refund_due && b.amount_pence > b.refunded_pence)
            .map((b) => ({
                bookingId: b.id,
                student: names.get(b.id) ?? "Student removed",
                pence: b.amount_pence - b.refunded_pence,
              }))
        : [],
      bookingClosed: e.status === "published" && isClosed({ booking_deadline: e.booking_deadline, starts_at: e.starts_at }, new Date()),
      hasBookings: bs.length > 0,
      hasPaper: withPaper.has(e.id),
      releaseAt:
        e.released_early_at ?? new Date(Date.parse(e.starts_at) - (e.release_minutes_before ?? 0) * 60_000).toISOString(),
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
  "id, title, paper, subject_id, format, starts_at, duration_minutes, price_pence, price_confirmed, booking_deadline, home_rules, allowed_materials, status, release_minutes_before, released_early_at, subject:subjects(name), centres:exam_centres(id, venue_id, room, seat_limit, removed_at, created_at, venue:venues(name))";
const TEACHER_COLUMNS =
  "id, title, paper, subject_id, format, starts_at, duration_minutes, booking_deadline, home_rules, allowed_materials, status, subject:subjects(name), centres:exam_centres(id, venue_id, room, seat_limit, removed_at, created_at, venue:venues(name))";

/** The ids (of these exams) that have a current question paper. */
async function loadExamsWithPaper(examIds: string[]): Promise<Set<string>> {
  const supabase = await createClient();
  const out = new Set<string>();
  for (const ids of chunk(examIds, ID_BATCH)) {
    for (let from = 0; ; from += PAGE) {
      const { data, error } = await supabase
        .from("exam_papers")
        .select("exam_id")
        .in("exam_id", ids)
        .eq("kind", "paper")
        .is("superseded_at", null)
        .order("id", { ascending: true })
        .range(from, from + PAGE - 1);
      if (error) throw new Error("papers could not be loaded");
      for (const r of data ?? []) out.add(r.exam_id);
      if ((data ?? []).length < PAGE) break;
    }
  }
  return out;
}

/** Published exams that are still to start and whose current question paper's page roles nobody has checked: no copy
 * is made for candidates until they are (the admin home page decides which are close to release). */
export async function loadExamsRolesUnchecked(): Promise<{ id: string; title: string; paper: string; startsAt: string; releaseAt: string }[]> {
  await requireStaff(["admin", "owner"]);
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("exam_papers")
    .select("exam:exams!inner(id, title, paper, starts_at, status, release_minutes_before, released_early_at)")
    .eq("kind", "paper")
    .is("superseded_at", null)
    .is("pages_reviewed_at", null)
    .eq("exam.status", "published")
    .gt("exam.starts_at", new Date().toISOString())
    .limit(EXAM_CAP);
  if (error) throw new Error("papers could not be loaded");
  return (data ?? [])
    .map((r) => r.exam)
    .sort((a, b) => a.starts_at.localeCompare(b.starts_at))
    .map((e) => ({
      id: e.id,
      title: e.title,
      paper: e.paper,
      startsAt: e.starts_at,
      releaseAt: e.released_early_at ?? new Date(Date.parse(e.starts_at) - e.release_minutes_before * 60_000).toISOString(),
    }));
}

/** Published exams that are still to start and have no question paper yet (the admin home page decides which are close to release). */
export async function loadExamsMissingPaper(): Promise<{ id: string; title: string; paper: string; startsAt: string; releaseAt: string }[]> {
  await requireStaff(["admin", "owner"]);
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("exams")
    .select("id, title, paper, starts_at, release_minutes_before, released_early_at")
    .eq("status", "published")
    .gt("starts_at", new Date().toISOString())
    .order("starts_at", { ascending: true })
    .limit(EXAM_CAP);
  if (error) throw new Error("exams could not be loaded");
  const rows = data ?? [];
  const withPaper = await loadExamsWithPaper(rows.map((r) => r.id));
  return rows
    .filter((r) => !withPaper.has(r.id))
    .map((r) => ({
      id: r.id,
      title: r.title,
      paper: r.paper,
      startsAt: r.starts_at,
      releaseAt: r.released_early_at ?? new Date(Date.parse(r.starts_at) - r.release_minutes_before * 60_000).toISOString(),
    }));
}

/** The admin exams screen: every exam, its seats and money, plus the subjects and venues the form needs. */
export async function loadAdminExams() {
  await requireStaff(["admin", "owner"]);
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("exams")
    .select(ADMIN_COLUMNS)
    .order("starts_at", { ascending: false })
    .limit(EXAM_CAP);
  if (error) throw new Error("exams could not be loaded");
  const exams = (data ?? []) as unknown as ExamQueryRow[];
  const cancelledIds = exams.filter((e) => e.status === "cancelled").map((e) => e.id);
  const [bookings, names, subjects, venues, withPaper] = await Promise.all([
    loadBookings(exams.map((e) => e.id)),
    loadRefundNames(cancelledIds),
    loadSubjects(),
    loadVenues(),
    loadExamsWithPaper(exams.map((e) => e.id)),
  ]);
  return { exams: toRows(exams, bookings, names, withPaper), subjects, venues, capped: exams.length >= EXAM_CAP };
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
