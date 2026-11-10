import "server-only";
import { chunk } from "@/lib/chunk";
import { likePattern, searchWords } from "@/lib/booking-search";
import { createClient } from "@/lib/supabase/server";
import { requireStaff } from "@/lib/staff-gate";
import { STATUS_LABEL, type BookingStatus } from "@/components/bookings/status";

type Embedded<T> = T | T[] | null;
const one = <T,>(v: Embedded<T>): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));

type Client = Awaited<ReturnType<typeof createClient>>;

export type AdminBookingRow = {
  id: string;
  status: BookingStatus;
  student: string;
  indexNumber: string | null;
  examId: string;
  examTitle: string;
  subject: string;
  startsAt: string;
  examStatus: "draft" | "published" | "cancelled" | "completed";
  amountPence: number;
  refundedPence: number;
  refundDue: boolean;
  paidOffline: boolean;
  paidAt: string | null;
  notes: string | null;
  createdAt: string;
};

export type ExamOption = {
  id: string;
  label: string;
  startsAt: string;
  status: string;
  /** Published, price confirmed and not started: the add form offers only these. */
  bookable: boolean;
};

export type StudentOption = { id: string; name: string; indexNumber: string | null };

/** The list is capped here, newest first. */
export const BOOKING_CAP = 500;
const PAGE = 1000;
const ID_BATCH = 100;
/** Student matches taken from one search (a name search is not a report). */
const STUDENT_MATCH_CAP = 300;

const STATUSES = Object.keys(STATUS_LABEL) as BookingStatus[];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const COLUMNS =
  "id, status, amount_pence, refunded_pence, refund_due, paid_offline, paid_at, notes, created_at, exam_id, student_id, " +
  "exam:exams(title, paper, starts_at, status, subject:subjects(name)), " +
  "student:profiles!bookings_student_id_fkey(first_name, last_name, student_details!profile_id(index_number))";

type QueryRow = {
  id: string;
  status: BookingStatus;
  amount_pence: number;
  refunded_pence: number;
  refund_due: boolean;
  paid_offline: boolean;
  paid_at: string | null;
  notes: string | null;
  created_at: string;
  exam_id: string;
  exam: Embedded<{ title: string; paper: string; starts_at: string; status: AdminBookingRow["examStatus"]; subject: Embedded<{ name: string }> }>;
  student: Embedded<{ first_name: string; last_name: string; student_details: Embedded<{ index_number: string | null }> }>;
};

function toRow(r: QueryRow): AdminBookingRow {
  const exam = one(r.exam);
  const st = one(r.student);
  return {
    id: r.id,
    status: r.status,
    student: st ? `${st.first_name} ${st.last_name}`.trim() : "Student removed",
    indexNumber: st ? (one(st.student_details)?.index_number ?? null) : null,
    examId: r.exam_id,
    examTitle: exam ? (exam.paper ? `${exam.title} (${exam.paper})` : exam.title) : "",
    subject: exam ? (one(exam.subject)?.name ?? "") : "",
    startsAt: exam?.starts_at ?? "",
    examStatus: exam?.status ?? "published",
    amountPence: r.amount_pence,
    refundedPence: r.refunded_pence,
    refundDue: r.refund_due,
    paidOffline: r.paid_offline,
    paidAt: r.paid_at,
    notes: r.notes,
    createdAt: r.created_at,
  };
}

/**
 * Active students whose first name, last name or index number contains every word of the search. Each word is
 * one parameterised `ilike` filter value (wildcards escaped), so commas and brackets cannot change the query.
 */
export async function findStudentIds(supabase: Client, raw: string, limit = STUDENT_MATCH_CAP): Promise<string[]> {
  const words = searchWords(raw);
  if (words.length === 0) return [];
  let acc: Set<string> | null = null as Set<string> | null;
  for (const w of words) {
    const pat = likePattern(w);
    const [first, last, idx] = await Promise.all([
      supabase.from("profiles").select("id").eq("role", "student").eq("status", "active").ilike("first_name", pat).limit(1000),
      supabase.from("profiles").select("id").eq("role", "student").eq("status", "active").ilike("last_name", pat).limit(1000),
      supabase.from("student_details").select("profile_id").ilike("index_number", pat).limit(1000),
    ]);
    if (first.error || last.error || idx.error) throw new Error("students could not be searched");
    const hit = new Set<string>([...(first.data ?? []).map((r) => r.id), ...(last.data ?? []).map((r) => r.id)]);
    // An index-number match must also be an active student.
    const idxIds = (idx.data ?? []).map((r) => r.profile_id);
    for (const ids of chunk(idxIds, ID_BATCH)) {
      const { data, error } = await supabase.from("profiles").select("id").eq("role", "student").eq("status", "active").in("id", ids);
      if (error) throw new Error("students could not be searched");
      for (const r of data ?? []) hit.add(r.id);
    }
    const prev: Set<string> | null = acc;
    acc = prev ? new Set([...prev].filter((id) => hit.has(id))) : hit;
    if (acc.size === 0) return [];
  }
  return [...(acc ?? [])].slice(0, limit);
}

/** Active students for the add-booking form, with their index numbers. */
export async function searchStudents(raw: string): Promise<StudentOption[]> {
  await requireStaff(["admin", "owner"]);
  const supabase = await createClient();
  const ids = await findStudentIds(supabase, raw, 20);
  if (ids.length === 0) return [];
  const { data, error } = await supabase
    .from("profiles")
    .select("id, first_name, last_name, student_details!profile_id(index_number)")
    .in("id", ids)
    .order("last_name")
    .order("first_name");
  if (error) throw new Error("students could not be loaded");
  const rows = (data ?? []) as unknown as { id: string; first_name: string; last_name: string; student_details: Embedded<{ index_number: string | null }> }[];
  return rows.map((p) => ({
    id: p.id,
    name: `${p.first_name} ${p.last_name}`.trim(),
    indexNumber: one(p.student_details)?.index_number ?? null,
  }));
}

export type BookingFilters = { status?: string; exam?: string; q?: string };

/** The bookings list under the filters, newest first, at most BOOKING_CAP rows (`capped` when there were more). */
async function loadList(supabase: Client, f: BookingFilters): Promise<{ rows: AdminBookingRow[]; capped: boolean }> {
  const status = f.status && (STATUSES as string[]).includes(f.status) ? f.status : null;
  const exam = f.exam && UUID.test(f.exam) ? f.exam : null;
  const q = (f.q ?? "").trim();

  const run = async (studentIds: string[] | null) => {
    let query = supabase.from("bookings").select(COLUMNS);
    if (status) query = query.eq("status", status as BookingStatus);
    if (exam) query = query.eq("exam_id", exam);
    if (studentIds) query = query.in("student_id", studentIds);
    const { data, error } = await query
      .order("created_at", { ascending: false })
      .order("id", { ascending: false })
      .limit(BOOKING_CAP + 1);
    if (error) throw new Error("bookings could not be loaded");
    return (data ?? []) as unknown as QueryRow[];
  };

  let rows: QueryRow[];
  if (q) {
    const ids = await findStudentIds(supabase, q);
    if (ids.length === 0) return { rows: [], capped: false };
    rows = (await Promise.all(chunk(ids, ID_BATCH).map(run))).flat();
    rows.sort((a, b) => (a.created_at === b.created_at ? (a.id < b.id ? 1 : -1) : a.created_at < b.created_at ? 1 : -1));
  } else {
    rows = await run(null);
  }
  const capped = rows.length > BOOKING_CAP;
  return { rows: rows.slice(0, BOOKING_CAP).map(toRow), capped };
}

/** Every booking an admin can decide on: cancellation requests, and refund-due rows still part refunded or cancelled. */
async function loadDecidable(supabase: Client): Promise<AdminBookingRow[]> {
  const out = new Map<string, AdminBookingRow>();
  const page = async (build: (from: number) => PromiseLike<{ data: unknown; error: unknown }>) => {
    for (let from = 0; ; from += PAGE) {
      const { data, error } = await build(from);
      if (error) throw new Error("cancellation requests could not be loaded");
      const rows = (data ?? []) as QueryRow[];
      for (const r of rows) out.set(r.id, toRow(r));
      if (rows.length < PAGE) break;
    }
  };
  await page((from) =>
    supabase.from("bookings").select(COLUMNS).eq("status", "cancel_requested").order("created_at").order("id").range(from, from + PAGE - 1),
  );
  await page((from) =>
    supabase
      .from("bookings")
      .select(COLUMNS)
      .eq("refund_due", true)
      .in("status", ["part_refunded", "cancelled"])
      .order("created_at")
      .order("id")
      .range(from, from + PAGE - 1),
  );
  return [...out.values()].sort((a, b) => (a.createdAt < b.createdAt ? -1 : 1));
}

async function loadExamOptions(supabase: Client): Promise<ExamOption[]> {
  const { data, error } = await supabase
    .from("exams")
    .select("id, title, paper, starts_at, status, price_confirmed, subject:subjects(name)")
    .order("starts_at", { ascending: false })
    .limit(500);
  if (error) throw new Error("exams could not be loaded");
  const now = Date.now();
  const rows = (data ?? []) as unknown as { id: string; title: string; paper: string; starts_at: string; status: string; price_confirmed: boolean; subject: Embedded<{ name: string }> }[];
  return rows.map((e) => ({
    id: e.id,
    label: `${one(e.subject)?.name ?? ""} · ${e.title}${e.paper ? ` (${e.paper})` : ""}`,
    startsAt: e.starts_at,
    status: e.status,
    bookable: e.status === "published" && e.price_confirmed && Date.parse(e.starts_at) > now,
  }));
}

/** The admin bookings screen. Owner and admin only; reads through the signed-in session (RLS applies). */
export async function loadAdminBookings(filters: BookingFilters) {
  await requireStaff(["admin", "owner"]);
  const supabase = await createClient();
  const [list, decidable, exams] = await Promise.all([loadList(supabase, filters), loadDecidable(supabase), loadExamOptions(supabase)]);
  return { rows: list.rows, capped: list.capped, decidable, exams };
}
