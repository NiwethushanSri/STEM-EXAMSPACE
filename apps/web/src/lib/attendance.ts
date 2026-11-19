import "server-only";
import { chunk } from "@/lib/chunk";
import type { ExamFormat } from "@/lib/exam-form";
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
  format: ExamFormat;
  /** Current centres only; a home-only exam has none and no register. */
  centres: { venue: string; room: string }[];
};

type ExamQuery = {
  id: string;
  title: string;
  paper: string;
  subject_id: number;
  starts_at: string;
  duration_minutes: number;
  status: string;
  format: ExamFormat;
  subject: Embedded<{ name: string }>;
  centres: Embedded<CentreQuery>[] | null;
};
type CentreQuery = {
  id: string;
  room: string;
  register_closed_at: string | null;
  removed_at: string | null;
  created_at: string;
  venue: Embedded<{ name: string }>;
};
const EXAM_COLUMNS =
  "id, title, paper, subject_id, starts_at, duration_minutes, status, format, subject:subjects(name), centres:exam_centres(id, room, register_closed_at, removed_at, created_at, venue:venues(name))";

/** The current centres of an exam, by venue then room. Archived centres (removed_at set) stay readable through RLS but have no register. */
function currentCentres(e: ExamQuery): CentreQuery[] {
  return (e.centres ?? [])
    .map((c) => one(c))
    .filter((c): c is CentreQuery => c !== null && c.removed_at === null)
    .sort((a, b) => (one(a.venue)?.name ?? "").localeCompare(one(b.venue)?.name ?? "") || a.room.localeCompare(b.room) || a.id.localeCompare(b.id));
}

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
    format: e.format,
    centres: currentCentres(e).map((c) => ({ venue: one(c.venue)?.name ?? "", room: c.room })),
  }));
}

export type RegisterCentre = { id: string; venue: string; room: string; open: boolean };

export type RegisterData = {
  exam: {
    id: string;
    title: string;
    paper: string;
    subject: string;
    startsAt: string;
    durationMinutes: number;
    format: ExamFormat;
    status: string;
  };
  /** Every current centre of the exam, with whether its register is still open. */
  centres: RegisterCentre[];
  /** The centre whose register this is; null while a choice among several is still to be made, or for an exam with no centre. */
  centre: RegisterCentre | null;
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
export async function loadRegister(area: Area, examId: string, centreId?: string | null): Promise<RegisterData | null> {
  const me = await requireStaff(ROLES[area]);
  if (!isUuid(examId)) return null;
  const supabase = await createClient();
  const { data: row } = await supabase.from("exams").select(EXAM_COLUMNS).eq("id", examId).maybeSingle();
  const e = row as unknown as ExamQuery | null;
  if (!e || (e.status !== "published" && e.status !== "completed")) return null;
  if (area === "teacher" && !(await teacherSubjects(me.id)).includes(e.subject_id)) return null;

  const live = e.status === "published";
  const centres: RegisterCentre[] = currentCentres(e).map((c) => ({
    id: c.id,
    venue: one(c.venue)?.name ?? "",
    room: c.room,
    open: live && c.register_closed_at === null,
  }));
  // One centre is chosen for the staff member; with several the page asks first (centre is null).
  const centre = centres.length === 1 ? centres[0] : (centres.find((c) => c.id === centreId) ?? null);
  const exam = {
    id: e.id,
    title: e.title,
    paper: e.paper,
    subject: one(e.subject)?.name ?? "",
    startsAt: e.starts_at,
    durationMinutes: e.duration_minutes,
    format: e.format,
    status: e.status,
  };
  if (!centre) {
    return { exam, centres, centre: null, booked: 0, marked: 0, notMarked: [], absent: [], names: area === "admin", open: false };
  }

  // Home candidates are on no register: only bookings at this centre count.
  const [bookings, attendance] = await Promise.all([
    pages<{ student_id: string | null }>((from, to) =>
      supabase
        .from("bookings")
        .select("student_id")
        .eq("centre_id", centre.id)
        .eq("sitting", "centre")
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
    exam,
    centres,
    centre,
    booked: booked.length,
    marked,
    notMarked: notMarkedIds.map(label).sort(byName),
    absent: absentIds.map(label).sort(byName),
    names: canSeeNames,
    open: centre.open,
  };
}
