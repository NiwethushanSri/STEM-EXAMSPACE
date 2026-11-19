"use server";

import { revalidatePath } from "next/cache";
import { attendanceMessageFor, type AttendanceContext } from "@stem/shared";
import { isUuid } from "@/lib/uuid";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

/** The register is for owner/admin and teachers; the database also checks the teacher teaches the exam's subject. */
const STAFF = ["admin", "owner", "teacher"] as const;
type Mark = "present" | "late" | "absent";

export type LookupOutcome =
  | { ok: true; studentId: string; name: string; photoUrl: string | null; status: Mark | null }
  | { ok: false; message: string };
export type MarkOutcome = { ok: true; status: Mark; already: boolean } | { ok: false; message: string };
export type CloseOutcome = { ok: true; absent: number } | { ok: false; message: string };

const isMark = (v: unknown): v is Mark => v === "present" || v === "late" || v === "absent";
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

function failure(data: unknown, error: unknown, context: AttendanceContext): { ok: false; message: string } {
  const code = !error && isObject(data) && typeof data.code === "string" ? data.code : undefined;
  return { ok: false, message: attendanceMessageFor(code, context) };
}

/** A register page is addressed by exam and centre (?centre=), so every register page is refreshed. */
function refresh() {
  revalidatePath("/admin/attendance/[examId]", "page");
  revalidatePath("/teacher/attendance/[examId]", "page");
  revalidatePath("/admin/attendance");
  revalidatePath("/teacher/attendance");
}

/**
 * Looks a student up by typed or scanned index number, for the register of one centre. The database normalises the text itself. The photo
 * is a 60-second signed URL made with the caller's own session: the storage policy lets owner/admin read
 * any student photo and no one else but the student, so a teacher gets "Photo unavailable" (null here).
 */
export async function lookupAction(centreId: string, index: string): Promise<LookupOutcome> {
  await requireStaff(STAFF);
  const text = typeof index === "string" ? index.trim() : "";
  if (!isUuid(centreId) || text === "" || text.length > 40) return { ok: false, message: attendanceMessageFor("invalid_input", "lookup") };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("attendance_lookup", { p_centre: centreId, p_index: text });
  if (error || !isObject(data) || data.ok !== true) return failure(data, error, "lookup");
  if (data.booked !== true || typeof data.studentId !== "string") return { ok: false, message: attendanceMessageFor("not_booked", "mark") };

  const studentId = data.studentId;
  let photoUrl: string | null = null;
  // Only the student's own object path is signed; anything else from the row is ignored.
  if (typeof data.photoPath === "string" && data.photoPath === `${studentId}/photo.jpg`) {
    const signed = await supabase.storage.from("student-photos").createSignedUrl(data.photoPath, 60);
    photoUrl = signed.error ? null : (signed.data?.signedUrl ?? null);
  }
  return {
    ok: true,
    studentId,
    name: typeof data.name === "string" ? data.name : "",
    photoUrl,
    status: isMark(data.status) ? data.status : null,
  };
}

export async function markAction(centreId: string, studentId: string): Promise<MarkOutcome> {
  await requireStaff(STAFF);
  if (!isUuid(centreId) || !isUuid(studentId)) return { ok: false, message: attendanceMessageFor("not_found", "mark") };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("mark_attendance", { p_centre: centreId, p_student: studentId });
  refresh();
  if (error || !isObject(data) || data.ok !== true || !isMark(data.status)) return failure(data, error, "mark");
  return { ok: true, status: data.status, already: data.already === true };
}

export async function closeRegisterAction(centreId: string): Promise<CloseOutcome> {
  await requireStaff(STAFF);
  if (!isUuid(centreId)) return { ok: false, message: attendanceMessageFor("not_found", "close") };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("close_register", { p_centre: centreId });
  refresh();
  if (error || !isObject(data) || data.ok !== true) return failure(data, error, "close");
  return { ok: true, absent: typeof data.absent === "number" ? data.absent : 0 };
}
