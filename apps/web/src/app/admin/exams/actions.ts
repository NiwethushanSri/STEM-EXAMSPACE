"use server";

import { revalidatePath } from "next/cache";
import { messageFor } from "@stem/shared";
import { callSaveExam, explainSaveConflict, readRpc } from "@/lib/exam-rpc";
import { parseExamForm } from "@/lib/exam-form";
import { isUuid } from "@/lib/uuid";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

/** What the exam actions send back; they never throw for expected failures. */
export type ExamActionResult = { ok: true; message: string } | { ok: false; message: string };

function refresh() {
  revalidatePath("/admin/exams");
  revalidatePath("/teacher/exams");
  revalidatePath("/exams");
}

/** Create or edit an exam (owner and admin). The form fields arrive as strings; save_exam re-checks every rule. */
export async function saveExamAction(raw: Record<string, string>): Promise<ExamActionResult> {
  await requireStaff(["admin", "owner"]);
  const parsed = parseExamForm(raw ?? {}, { withPrice: true });
  if (!parsed.ok) return { ok: false, message: parsed.error };
  const v = parsed.value;

  const supabase = await createClient();
  const { data, error } = await callSaveExam(supabase, v, v.pricePence ?? 0);
  const out = readRpc(data, error, "save_exam");
  refresh();
  if (out.ok) return { ok: true, message: v.id ? "Exam saved." : "Exam created as a draft. Publish it when it is ready." };
  const code = data && typeof data === "object" && !Array.isArray(data) ? (data as { code?: unknown }).code : undefined;
  if (code === "conflict") return { ok: false, message: await explainSaveConflict(supabase, v) };
  return out;
}

/** Publish a draft or cancel a published exam (owner and admin). Cancelling flags paid bookings for refund. */
export async function setExamStatusAction(examId: string, status: "published" | "cancelled"): Promise<ExamActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId) || (status !== "published" && status !== "cancelled")) {
    return { ok: false, message: messageFor("invalid_input") };
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_exam_status", { p_id: examId, p_status: status });
  const out = readRpc(data, error, "set_status");
  refresh();
  if (!out.ok) return out;
  if (status === "published") return { ok: true, message: "Exam published. Families can book it now." };

  // Tell the admin what the cancel did to the bookings.
  const { count } = await supabase
    .from("bookings")
    .select("id", { count: "exact", head: true })
    .eq("exam_id", examId)
    .eq("refund_due", true);
  const n = count ?? 0;
  return {
    ok: true,
    message:
      n > 0
        ? `Exam cancelled. ${n} booking${n === 1 ? " is" : "s are"} flagged for a refund; see the exam row. Unpaid bookings were cancelled.`
        : "Exam cancelled. There were no paid bookings to refund.",
  };
}

