import "server-only";
import { chunk } from "@/lib/chunk";
import { isUuid } from "@/lib/uuid";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

export type Area = "admin" | "teacher";
const ROLES = { admin: ["admin", "owner"], teacher: ["teacher"] } as const;


type Embedded<T> = T | T[] | null;
const one = <T,>(v: Embedded<T>): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));

const PAGE = 1000;
const ID_BATCH = 100;
/** Completed exams stay on the picker this long. */
const RECENT_DAYS = 14;
const PICKER_CAP = 200;

export type PickerExam = {
  id: string;
  title: string;
  paper: string;
  subject: string;
  startsAt: string;
  status: "published" | "completed";
  room: string | null;
  venue: string | null;
};

type ExamQuery = {
  id: string;
  title: string;
  paper: string;
  subject_id: number;
  starts_at: string;
  duration_minutes: number;
  status: string;
  room: string | null;
  format: string;
  subject: Embedded<{ name: string }>;
  venue: Embedded<{ name: string }>;
};
const EXAM_COLUMNS = "id, title, paper, subject_id, starts_at, duration_minutes, status, room, format, subject:subjects(name), venue:venues(name)";

/** The teacher's own subjects. An empty list means no exams at all. */
async function teacherSubjects(userId: string): Promise<number[]> {
  const supabase = await createClient();
  const { data } = await supabase.from("teacher_subjects").select("subject_id").eq("teacher_id", userId);
  return (data ?? []).map((l) => l.subject_id);
}

/** Published exams from the last 14 days on (so a forgotten, unclosed register stays reachable) and recently completed ones, by start time. */
export async function loadPicker(area: Area): Promise<PickerExam[]> {
  const me = await requireStaff(ROLES[area]);
  const supabase = await createClient();
  const now = Date.now();
  const recentFrom = new Date(now - RECENT_DAYS * 86400_000).toISOString();

  let subjects: number[] | null = null;
  if (area === "teacher") {
    subjects = await teacherSubjects(me.id);
    if (subjects.length === 0) return [];
  }
  let q = supabase
    .from("exams")
    .select(EXAM_COLUMNS)
    .or(`and(status.eq.published,starts_at.gte.${recentFrom}),and(status.eq.completed,starts_at.gte.${recentFrom})`)
    .order("starts_at", { ascending: true })
    .limit(PICKER_CAP);
  if (subjects) q = q.in("subject_id", subjects);
  const { data, error } = await q;
  if (error) throw new Error("exams could not be loaded");
  return ((data ?? []) as unknown as ExamQuery[]).map((e) => ({
    id: e.id,
    title: e.title,
    paper: e.paper,
    subject: one(e.subject)?.name ?? "",
    startsAt: e.starts_at,
    status: e.status === "completed" ? "completed" : "published",
    room: e.room,
    venue: one(e.venue)?.name ?? null,
  }));
}

export type RegisterData = {
  exam: {
    id: string;
    title: string;
    paper: string;
    subject: string;
    startsAt: string;
    durationMinutes: number;
    format: string;
    venue: string | null;
    room: string | null;
    status: string;
  };
  booked: number;
  marked: number;
  /** Booked students with no attendance row yet. `names` is false when the viewer cannot read student names. */
  notMarked: { id: string; name: string }[];
  absent: { id: string; name: string }[];
  names: boolean;
  open: boolean;
};

async function pages<T>(run: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: unknown }>): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await run(from, from + PAGE - 1);
    if (error) throw new Error("attendance could not be loaded");
    out.push(...(data ?? []));
    if ((data ?? []).length < PAGE) break;
  }
  return out;
}

/**
 * Everything the register page shows. Returns null when the exam does not exist or is not the viewer's to
 * see (a teacher of another subject, a draft, a cancelled exam). Student names come from `profiles`
 * through RLS, so only owner/admin get them; a teacher sees counts only.
 */
export async function loadRegister(area: Area, examId: string): Promise<RegisterData | null> {
  const me = await requireStaff(ROLES[area]);
  if (!isUuid(examId)) return null;
  const supabase = await createClient();
  const { data: row } = await supabase.from("exams").select(EXAM_COLUMNS).eq("id", examId).maybeSingle();
  const e = row as unknown as ExamQuery | null;
  if (!e || (e.status !== "published" && e.status !== "completed")) return null;
  if (area === "teacher" && !(await teacherSubjects(me.id)).includes(e.subject_id)) return null;

  const [bookings, attendance] = await Promise.all([
    pages<{ student_id: string | null }>((from, to) =>
      supabase
        .from("bookings")
        .select("student_id")
        .eq("exam_id", examId)
        .in("status", ["paid", "cancel_requested"])
        .order("id", { ascending: true })
        .range(from, to),
    ),
    pages<{ student_id: string; status: string }>((from, to) =>
      supabase.from("attendance").select("student_id, status").eq("exam_id", examId).order("student_id", { ascending: true }).range(from, to),
    ),
  ]);
  const booked = [...new Set(bookings.map((b) => b.student_id).filter((v): v is string => v !== null))];
  const byStudent = new Map(attendance.map((a) => [a.student_id, a.status]));
  const bookedSet = new Set(booked);
  const marked = attendance.filter((a) => (a.status === "present" || a.status === "late") && bookedSet.has(a.student_id)).length;
  const notMarkedIds = booked.filter((id) => !byStudent.has(id));
  const absentIds = booked.filter((id) => byStudent.get(id) === "absent");

  const names = new Map<string, string>();
  const canSeeNames = area === "admin";
  if (canSeeNames) {
    for (const ids of chunk([...notMarkedIds, ...absentIds], ID_BATCH)) {
      const { data, error } = await supabase.from("profiles").select("id, first_name, last_name").in("id", ids);
      if (error) throw new Error("student names could not be loaded");
      for (const p of data ?? []) names.set(p.id, `${p.first_name} ${p.last_name}`.trim());
    }
  }
  const label = (id: string) => ({ id, name: names.get(id) ?? "Student" });
  const byName = (a: { name: string }, b: { name: string }) => a.name.localeCompare(b.name);

  return {
    exam: {
      id: e.id,
      title: e.title,
      paper: e.paper,
      subject: one(e.subject)?.name ?? "",
      startsAt: e.starts_at,
      durationMinutes: e.duration_minutes,
      format: e.format,
      venue: one(e.venue)?.name ?? null,
      room: e.room,
      status: e.status,
    },
    booked: booked.length,
    marked,
    notMarked: notMarkedIds.map(label).sort(byName),
    absent: absentIds.map(label).sort(byName),
    names: canSeeNames,
    open: e.status === "published",
  };
}
