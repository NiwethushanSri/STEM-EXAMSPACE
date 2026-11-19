"use server";

import { revalidatePath } from "next/cache";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

/** What these actions send back; they never throw for expected failures. */
export type PaperActionResult = { ok: true; message: string } | { ok: false; message: string };

const GENERIC = "Something went wrong. Please try again.";

const CONFLICTS = {
  settings: "This exam is cancelled or finished, or another exam already uses that code, or copies already exist so the code can no longer change.",
  release: "The paper cannot be released now. It needs a current paper, a published exam and a release time that has not passed yet.",
  hold: "The release is already held, or the exam is not published.",
  resume: "The release is not held, or the exam is not published.",
  insert: "This insert has already been removed.",
} as const;

function answer(
  data: unknown,
  error: unknown,
  conflict: string,
  done: string,
): PaperActionResult {
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, message: GENERIC };
  const res = data as { ok?: unknown; code?: unknown };
  if (res.ok === true) return { ok: true, message: done };
  switch (res.code) {
    case "invalid_input":
      return { ok: false, message: "Check the details and try again. A reason needs 3 to 300 characters." };
    case "conflict":
      return { ok: false, message: conflict };
    case "not_found":
      return { ok: false, message: "That could not be found. Refresh the page and try again." };
    case "forbidden":
      return { ok: false, message: "You do not have permission to do this." };
    default:
      return { ok: false, message: GENERIC };
  }
}

function refresh(examId: string) {
  revalidatePath(`/admin/exams/${examId}`);
  revalidatePath("/admin/exams");
  revalidatePath("/admin");
}

/** Asked for when the release minutes of a published exam change without a reason. */
const REASON_REQUIRED =
  "Changing the release time of a published exam needs a reason (3 to 300 characters). It goes into the audit log.";

/** Exam code, release minutes before the start, and spare answer pages. Changing the minutes of a published exam
 * needs a reason. The database re-checks every rule and records the old and new values. */
export async function saveSettingsAction(
  examId: string,
  settings: { examCode: string; releaseMinutes: number; sparePages: number; reason?: string },
): Promise<PaperActionResult & { reasonRequired?: boolean }> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("set_exam_paper_settings", {
    p_exam: examId,
    p_exam_code: settings.examCode,
    p_release_minutes_before: settings.releaseMinutes,
    p_spare_pages: settings.sparePages,
    p_reason: settings.reason?.trim() ? settings.reason.trim() : undefined,
  });
  refresh(examId);
  if (!error && data && typeof data === "object" && !Array.isArray(data) && (data as { code?: unknown }).code === "reason_required") {
    return { ok: false, message: REASON_REQUIRED, reasonRequired: true };
  }
  return answer(data, error, CONFLICTS.settings, "Paper settings saved.");
}

type ReleaseKind = "release" | "hold" | "resume";
const RELEASE_FN = { release: "paper_release_now", hold: "paper_hold", resume: "paper_resume" } as const;
const RELEASE_DONE = { release: "The paper has been released.", hold: "The release is on hold.", resume: "The release has resumed." } as const;

/** Release now, hold or resume, each with a reason (3 to 300 characters) that goes into the audit log. */
export async function releaseAction(examId: string, kind: ReleaseKind, reason: string): Promise<PaperActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId) || !(kind in RELEASE_FN)) return { ok: false, message: GENERIC };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc(RELEASE_FN[kind], { p_exam: examId, p_reason: reason });
  refresh(examId);
  return answer(data, error, CONFLICTS[kind], RELEASE_DONE[kind]);
}

/** Takes an insert off the exam (it stays in the history). */
export async function removeInsertAction(examId: string, paperId: string, reason: string): Promise<PaperActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId) || !isUuid(paperId)) return { ok: false, message: GENERIC };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("remove_exam_insert", { p_paper: paperId, p_reason: reason });
  refresh(examId);
  return answer(data, error, CONFLICTS.insert, "The insert has been removed.");
}
