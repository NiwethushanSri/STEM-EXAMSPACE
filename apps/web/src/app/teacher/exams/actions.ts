"use server";

import { revalidatePath } from "next/cache";
import { callSaveExam, readRpc, saveHomeRules } from "@/lib/exam-rpc";
import { parseExamForm } from "@/lib/exam-form";
import type { FileBegun, StructurePayload, StructureResult } from "@/lib/exam-structure";
import { beginMarkSchemeFile, markSchemeFileStored, removeMarkSchemeFile, saveStructure } from "@/lib/exam-structure-server";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

export type TeacherExamResult = { ok: true; message: string; id?: string } | { ok: false; message: string };

/**
 * A teacher creates or edits a draft exam in one of their own subjects. The form has no price and the
 * price sent here is a placeholder: save_exam ignores it for teachers (a new exam is created at 0 and
 * unconfirmed, so an admin must set the price before it can be published).
 */
export async function saveTeacherExamAction(raw: Record<string, string>): Promise<TeacherExamResult> {
  await requireStaff(["teacher"]);
  const parsed = parseExamForm(raw ?? {}, { withPrice: false });
  if (!parsed.ok) return { ok: false, message: parsed.error };

  const supabase = await createClient();
  const { data, error } = await callSaveExam(supabase, parsed.value, 0);
  const out = readRpc(data, error, "save_exam");
  const rulesProblem = out.ok ? await saveHomeRules(supabase, out.id, parsed.value) : null;
  revalidatePath("/teacher/exams");
  revalidatePath("/admin/exams");
  if (!out.ok) return out;
  // The draft is saved, so this is a success with a warning: the form closes and cannot save a second copy.
  if (rulesProblem) return { ok: true, message: rulesProblem, id: out.id };
  return {
    ok: true,
    message: parsed.value.id ? "Draft saved." : "Draft created. An admin will set the price and publish it.",
  };
}

/**
 * A teacher of the exam's subject saves its questions and mark scheme. The database refuses another subject, and any
 * change once marking has opened (only an admin may then change it).
 */
export async function saveTeacherStructureAction(examId: string, structure: StructurePayload): Promise<StructureResult> {
  await requireStaff(["teacher"]);
  return saveStructure(examId, structure, undefined);
}

/** Starts a mark scheme PDF upload: the path the browser sends it to. */
export async function teacherMarkSchemeBeginAction(examId: string, bytes: number): Promise<FileBegun> {
  await requireStaff(["teacher"]);
  return beginMarkSchemeFile(examId, bytes);
}

/** The uploaded PDF becomes the exam's mark scheme. */
export async function teacherMarkSchemeStoredAction(examId: string, fileId: string): Promise<{ ok: boolean; code?: string }> {
  await requireStaff(["teacher"]);
  return markSchemeFileStored(examId, fileId);
}

/** Removes the mark scheme PDF, with a reason. */
export async function teacherMarkSchemeRemoveAction(examId: string, fileId: string, reason: string): Promise<StructureResult> {
  await requireStaff(["teacher"]);
  return removeMarkSchemeFile(examId, fileId, reason);
}
