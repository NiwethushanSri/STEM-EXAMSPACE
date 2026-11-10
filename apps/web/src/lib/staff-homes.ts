import "server-only";
import { chunk } from "@/lib/chunk";
import { loadTeacherExams } from "@/lib/exams-staff";
import { createClient } from "@/lib/supabase/server";
import { requireStaff } from "@/lib/staff-gate";
import type { BookingStatus } from "@/components/bookings/status";

const SEAT_STATUSES: BookingStatus[] = ["awaiting_payment", "paid", "cancel_requested"];
const ID_BATCH = 100;
const PAGE = 1000;
const TUTOR_CAP = 200;

type Embedded<T> = T | T[] | null;
const one = <T,>(v: Embedded<T>): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));

export type TeacherHomeExam = { id: string; title: string; paper: string; subject: string; startsAt: string; seatLimit: number; seatsBooked: number };

/** The teacher's own subjects: upcoming published exams with seats taken (counts only, no names, no prices) and the draft count. */
export async function loadTeacherHome(): Promise<{ upcoming: TeacherHomeExam[]; drafts: number }> {
  await requireStaff(["teacher"]);
  const { exams } = await loadTeacherExams();
  const now = Date.now();
  const drafts = exams.filter((e) => e.status === "draft").length;
  const upcoming = exams
    .filter((e) => e.status === "published" && Date.parse(e.startsAt) >= now)
    .sort((a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt));

  const supabase = await createClient();
  const counts = new Map<string, number>();
  for (const ids of chunk(
    upcoming.map((e) => e.id),
    ID_BATCH,
  )) {
    for (let from = 0; ; from += PAGE) {
      const { data, error } = await supabase
        .from("bookings")
        .select("id, exam_id")
        .in("exam_id", ids)
        .in("status", SEAT_STATUSES)
        .order("id", { ascending: true })
        .range(from, from + PAGE - 1);
      if (error) throw new Error("bookings could not be loaded");
      for (const b of data ?? []) counts.set(b.exam_id, (counts.get(b.exam_id) ?? 0) + 1);
      if ((data ?? []).length < PAGE) break;
    }
  }
  return {
    drafts,
    upcoming: upcoming.map((e) => ({
      id: e.id,
      title: e.title,
      paper: e.paper,
      subject: e.subject,
      startsAt: e.startsAt,
      seatLimit: e.seatLimit,
      seatsBooked: counts.get(e.id) ?? 0,
    })),
  };
}

export type TutorBookingRow = {
  id: string;
  student: string;
  status: BookingStatus;
  exam: { title: string; subject: string; startsAt: string };
};

/**
 * Live bookings of the tutor's assigned students. Everything is read with the tutor's own session, so
 * row-level security decides what is visible. The exam is an inner embed filtered on start time, so past
 * and unreadable exams drop out on the server and the cap applies to what is left.
 */
export async function loadTutorHome(): Promise<{ rows: TutorBookingRow[]; students: number; capped: boolean }> {
  const me = await requireStaff(["tutor"]);
  const supabase = await createClient();
  const { data: links, error: le } = await supabase.from("tutor_students").select("student_id").eq("tutor_id", me.id);
  if (le) throw new Error("students could not be loaded");
  const studentIds = (links ?? []).map((l) => l.student_id);
  if (studentIds.length === 0) return { rows: [], students: 0, capped: false };

  type Row = {
    id: string;
    status: BookingStatus;
    student: Embedded<{ first_name: string; last_name: string }>;
    exam: Embedded<{ title: string; starts_at: string; subject: Embedded<{ name: string }> }>;
  };
  const nowIso = new Date().toISOString();
  const all: Row[] = [];
  for (const ids of chunk(studentIds, ID_BATCH)) {
    for (let from = 0; ; from += PAGE) {
      const { data, error } = await supabase
        .from("bookings")
        .select("id, status, student:profiles!bookings_student_id_fkey(first_name, last_name), exam:exams!inner(title, starts_at, subject:subjects(name))")
        .in("student_id", ids)
        .in("status", SEAT_STATUSES)
        .gte("exam.starts_at", nowIso)
        .order("id", { ascending: true })
        .range(from, from + PAGE - 1);
      if (error) throw new Error("bookings could not be loaded");
      const rows = (data ?? []) as unknown as Row[];
      all.push(...rows);
      if (rows.length < PAGE) break;
    }
  }
  const rows: TutorBookingRow[] = [];
  for (const r of all) {
    const ex = one(r.exam);
    if (!ex) continue;
    const st = one(r.student);
    rows.push({
      id: r.id,
      status: r.status,
      student: st ? `${st.first_name} ${st.last_name}`.trim() : "Student",
      exam: { title: ex.title, subject: one(ex.subject)?.name ?? "", startsAt: ex.starts_at },
    });
  }
  rows.sort((a, b) => Date.parse(a.exam.startsAt) - Date.parse(b.exam.startsAt) || a.student.localeCompare(b.student));
  return { rows: rows.slice(0, TUTOR_CAP), students: studentIds.length, capped: rows.length > TUTOR_CAP };
}
