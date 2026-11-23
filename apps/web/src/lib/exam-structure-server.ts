import "server-only";
import { notFound } from "next/navigation";
import { revalidatePath } from "next/cache";
import type { AppRole } from "@stem/shared";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";
import {
  draftFromServer,
  structureFailure,
  type FileBegun,
  type StructurePayload,
  type StructureResult,
  type StructureView,
} from "@/lib/exam-structure";

/**
 * The questions and mark scheme screens (admin, and a teacher of the subject) and what their actions do. The database
 * decides who may read or change a structure (structure_can_edit) and re-checks every rule; the actions in the two
 * areas call these after their own requireStaff.
 */

const GENERIC = "Something went wrong. Please try again.";

export type StructureExam = { id: string; title: string; paper: string; subject: string };

type Embedded<T> = T | T[] | null;
const one = <T,>(v: Embedded<T>): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));

/** The exam and its structure; `problem` says why the structure could not be read (for example another subject). */
export async function loadExamStructure(
  examId: string,
  roles: readonly AppRole[],
): Promise<{ exam: StructureExam; view: StructureView | null; problem: string | null }> {
  await requireStaff(roles);
  if (!isUuid(examId)) notFound();
  const supabase = await createClient();
  const [examRes, structureRes] = await Promise.all([
    supabase.from("exams").select("id, title, paper, subject:subjects(name)").eq("id", examId).maybeSingle(),
    supabase.rpc("exam_structure_get", { p_exam: examId }),
  ]);
  if (examRes.error) throw new Error("exam could not be loaded");
  if (!examRes.data) notFound();
  const e = examRes.data;
  const view = draftFromServer(structureRes.data);
  return {
    exam: { id: e.id, title: e.title, paper: e.paper ?? "", subject: one(e.subject as Embedded<{ name: string }>)?.name ?? "" },
    view,
    problem: view ? null : (structureFailure(structureRes.data, structureRes.error, "save") ?? GENERIC),
  };
}

function refresh(examId: string) {
  revalidatePath(`/admin/exams/${examId}/structure`);
  revalidatePath(`/teacher/exams/${examId}/structure`);
}

/** Saves the whole structure (a reason once marking has opened) and answers with the saved structure. */
export async function saveStructure(examId: string, structure: StructurePayload, reason: string | undefined): Promise<StructureResult> {
  if (!isUuid(examId) || !structure || typeof structure !== "object" || Array.isArray(structure)) return { ok: false, message: GENERIC };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("exam_structure_save", {
    p_exam: examId,
    p_structure: structure,
    p_reason: reason?.trim() ? reason.trim() : undefined,
  });
  const failed = structureFailure(data, error, "save");
  if (failed) return { ok: false, message: failed };
  refresh(examId);
  const again = await supabase.rpc("exam_structure_get", { p_exam: examId });
  return { ok: true, message: "Saved.", view: draftFromServer(again.data) ?? undefined };
}

/** A pending mark scheme PDF: the path the browser uploads it to. */
export async function beginMarkSchemeFile(examId: string, bytes: number): Promise<FileBegun> {
  if (!isUuid(examId) || !Number.isSafeInteger(bytes)) return { ok: false, code: "invalid_input" };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("mark_scheme_file_begin", { p_exam: examId, p_bytes: bytes });
  const r = !error && data && typeof data === "object" && !Array.isArray(data) ? (data as Record<string, unknown>) : null;
  if (r?.ok === true && typeof r.file_id === "string" && typeof r.storage_path === "string") {
    return { ok: true, fileId: r.file_id, path: r.storage_path };
  }
  return { ok: false, code: typeof r?.code === "string" ? r.code : "internal" };
}

/** The uploaded PDF becomes the exam's mark scheme (an earlier one is replaced). */
export async function markSchemeFileStored(examId: string, fileId: string): Promise<{ ok: boolean; code?: string }> {
  if (!isUuid(examId) || !isUuid(fileId)) return { ok: false, code: "invalid_input" };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("mark_scheme_file_stored", { p_file: fileId });
  const r = !error && data && typeof data === "object" && !Array.isArray(data) ? (data as Record<string, unknown>) : null;
  if (r?.ok === true) {
    refresh(examId);
    return { ok: true };
  }
  return { ok: false, code: typeof r?.code === "string" ? r.code : "internal" };
}

/** Takes the PDF off the exam, with a reason (the file is kept). */
export async function removeMarkSchemeFile(examId: string, fileId: string, reason: string): Promise<StructureResult> {
  if (!isUuid(examId) || !isUuid(fileId)) return { ok: false, message: GENERIC };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("mark_scheme_file_remove", { p_file: fileId, p_reason: reason });
  const failed = structureFailure(data, error, "file");
  if (failed) return { ok: false, message: failed };
  refresh(examId);
  return { ok: true, message: "The mark scheme PDF has been removed." };
}
