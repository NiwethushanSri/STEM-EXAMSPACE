"use server";

import { revalidatePath } from "next/cache";
import { markingMessageFor } from "@stem/shared";
import { reasonProblem } from "@/lib/exception-queue";
import { noteProblem } from "@/lib/marking-approval";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

/** What these actions send back; they never throw for expected failures. */
export type ApprovalActionResult = { ok: true; message: string } | { ok: false; message: string };

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;

const GENERIC = markingMessageFor("internal");

/** Calls one approval function (the database checks the admin and every rule again) and refreshes the pages that show
 * the exam's marking. */
async function call(examId: string, fn: string, args: Record<string, unknown>, done: (a: Record<string, unknown>) => string): Promise<ApprovalActionResult> {
  const supabase = await createClient();
  const { data, error } = await (supabase.rpc as unknown as Rpc)(fn, { p_exam: examId, ...args });
  revalidatePath(`/admin/marking/${examId}/approval`);
  revalidatePath("/admin/marking");
  revalidatePath(`/admin/exams/${examId}`);
  revalidatePath("/marking");
  revalidatePath("/marking/review");
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, message: GENERIC };
  const a = data as Record<string, unknown>;
  if (a.ok === true) return { ok: true, message: done(a) };
  return { ok: false, message: markingMessageFor(typeof a.code === "string" ? a.code : null) };
}

/** Approves the exam's marking, with an optional note (up to 300 characters): marking closes and nothing about it can
 * change until an admin withdraws the approval. Refused while anything still blocks it. */
export async function approveMarking(examId: string, note: string): Promise<ApprovalActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  const text = (note ?? "").trim();
  const problem = noteProblem(text);
  if (problem) return { ok: false, message: problem };
  return call(examId, "marking_approve", text ? { p_note: text } : {}, (a) =>
    a.already === true ? "This exam's marking was already approved." : "This exam's marking is approved. Marking is closed.",
  );
}

/** Withdraws the approval, with a reason (3 to 300 characters). Marking stays closed until an admin reopens it. */
export async function withdrawApproval(examId: string, reason: string): Promise<ApprovalActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  return call(examId, "marking_approval_withdraw", { p_reason: reason.trim() }, (a) =>
    a.already === true ? "This exam's marking was not approved." : "The approval is withdrawn. Marking stays closed until an admin reopens it.",
  );
}
