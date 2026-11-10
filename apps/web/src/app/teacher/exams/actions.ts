"use server";

import { revalidatePath } from "next/cache";
import { callSaveExam, readRpc } from "@/lib/exam-rpc";
import { parseExamForm } from "@/lib/exam-form";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

export type TeacherExamResult = { ok: true; message: string } | { ok: false; message: string };

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
  revalidatePath("/teacher/exams");
  revalidatePath("/admin/exams");
  if (!out.ok) return out;
  return {
    ok: true,
    message: parsed.value.id ? "Draft saved." : "Draft created. An admin will set the price and publish it.",
  };
}
