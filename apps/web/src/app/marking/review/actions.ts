"use server";

import { revalidatePath } from "next/cache";
import { reviewMessageFor, standardMessageFor } from "@stem/shared";
import { reasonProblem } from "@/lib/exception-queue";
import { MARKING_ROLES } from "@/lib/marking-lists";
import { noteProblem, type MarkInput } from "@/lib/marking-review";
import { formatMark } from "@/lib/marking-screen";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

/** What these actions send back; they never throw for expected failures. A success may say what happened. */
export type ReviewActionResult = { ok: true; message?: string } | { ok: false; message: string };

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;
type Answer = Record<string, unknown>;

const GENERIC = reviewMessageFor("internal");
const INVALID = reviewMessageFor("invalid_input");
const OUTCOMES = ["first_stands", "second_stands", "lead_marks"] as const;
const scripts = (n: number) => `${n} ${n === 1 ? "script" : "scripts"}`;
const count = (v: unknown) => (typeof v === "number" && Number.isSafeInteger(v) ? v : 0);
const rev = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;

/** Calls one function as the signed-in user; null when the database could not answer. Every function checks again
 * that the caller is an admin or the subject's lead marker. */
async function call(fn: string, args: Record<string, unknown>): Promise<Answer | null> {
  const supabase = await createClient();
  const { data, error } = await (supabase.rpc as unknown as Rpc)(fn, args);
  revalidatePath("/marking/review");
  revalidatePath("/marking");
  revalidatePath("/admin/marking");
  return error || !data || typeof data !== "object" || Array.isArray(data) ? null : (data as Answer);
}

/** A refusal in the review's words (a conflict says why). */
function reviewRefusal(a: Answer | null): { ok: false; message: string } {
  if (!a) return { ok: false, message: GENERIC };
  return { ok: false, message: reviewMessageFor(typeof a.code === "string" ? a.code : null, typeof a.reason === "string" ? a.reason : null) };
}

/** A refusal of the practice, seeded script and clearance functions, in their words. */
function standardRefusal(a: Answer | null): { ok: false; message: string } {
  if (!a) return { ok: false, message: standardMessageFor("internal") };
  return { ok: false, message: standardMessageFor(typeof a.code === "string" ? a.code : null, typeof a.reason === "string" ? a.reason : null) };
}

/** 1 to 200 marks, each {question_id, mark|null, na} with a mark or NR and never both. Whether each is within its
 * question's maximum and step, and every question has one, is checked by the page (readMarks) and by the database. */
function goodMarks(marks: unknown): marks is MarkInput[] {
  return (
    Array.isArray(marks) &&
    marks.length >= 1 &&
    marks.length <= 200 &&
    marks.every(
      (m) =>
        m &&
        typeof m === "object" &&
        isUuid((m as MarkInput).question_id) &&
        typeof (m as MarkInput).na === "boolean" &&
        ((m as MarkInput).na ? (m as MarkInput).mark === null : typeof (m as MarkInput).mark === "number" && Number.isFinite((m as MarkInput).mark)),
    )
  );
}
const cleanMarks = (marks: MarkInput[]): MarkInput[] => marks.map((m) => ({ question_id: m.question_id, mark: m.na ? null : m.mark, na: m.na }));

/** Settles marks that differ: "First marks stand", "Second marks stand" or "Set my own marks" (marks: one per question,
 * a mark or NR), at the revs of the two markings shown (a marking changed since is refused: changed), with a reason. */
export async function settleReview(
  reviewId: string,
  outcome: string,
  firstRev: number,
  secondRev: number,
  reason: string,
  marks?: MarkInput[],
): Promise<ReviewActionResult> {
  await requireStaff(MARKING_ROLES);
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  const lead = outcome === "lead_marks";
  if (!isUuid(reviewId) || !OUTCOMES.includes(outcome as (typeof OUTCOMES)[number]) || !rev(firstRev) || !rev(secondRev) || (lead && !goodMarks(marks))) {
    return { ok: false, message: INVALID };
  }
  const a = await call("marking_review_settle", {
    p_review: reviewId,
    p_outcome: outcome,
    p_first_rev: firstRev,
    p_second_rev: secondRev,
    p_reason: reason.trim(),
    p_marks: lead ? cleanMarks(marks!) : null,
  });
  return a?.ok === true ? { ok: true } : reviewRefusal(a);
}

/** Accepts a paused marker's script (it is then checked on its first marks) or a script of the routine sample. The
 * reason is optional; given, it is 3 to 300 characters. */
export async function acceptReview(reviewId: string, reason?: string): Promise<ReviewActionResult> {
  await requireStaff(MARKING_ROLES);
  const problem = reasonProblem(reason ?? "", false);
  if (problem) return { ok: false, message: problem };
  if (!isUuid(reviewId)) return { ok: false, message: INVALID };
  const a = await call("marking_review_accept", { p_review: reviewId, p_reason: (reason ?? "").trim() || null });
  return a?.ok === true ? { ok: true } : reviewRefusal(a);
}

/** Sends a script back: to the same marker (their marking opens again with the note) or to another (it is free for
 * anyone else). The database sends it to another when the same marker can no longer have it, and the answer says so. */
export async function sendBack(unitId: string, to: string, note: string, reason: string): Promise<ReviewActionResult> {
  await requireStaff(MARKING_ROLES);
  const noteBad = noteProblem(note ?? "", true);
  if (noteBad) return { ok: false, message: noteBad };
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  if (!isUuid(unitId) || (to !== "same" && to !== "other")) return { ok: false, message: INVALID };
  const a = await call("marking_send_back", { p_unit: unitId, p_to: to, p_note: note.trim(), p_reason: reason.trim() });
  if (a?.ok !== true) return reviewRefusal(a);
  if (a.to === "same") return { ok: true, message: "Sent back to the same marker." };
  return {
    ok: true,
    message: to === "same" ? "The same marker can no longer mark this script, so another marker will mark it again." : "Another marker will mark this script again.",
  };
}

/** The routine sample: 1 to 20 of one marker's submitted scripts on the exam, each opened for the lead's review. The
 * scripts are not held back. */
export async function sampleMarker(examId: string, markerId: string, n: number): Promise<ReviewActionResult> {
  await requireStaff(MARKING_ROLES);
  if (!isUuid(examId) || !isUuid(markerId) || !Number.isSafeInteger(n) || n < 1 || n > 20) return { ok: false, message: INVALID };
  const a = await call("marking_review_sample", { p_exam: examId, p_marker: markerId, p_count: n });
  if (a?.ok !== true) return reviewRefusal(a);
  const added = count(a.added);
  return { ok: true, message: added === 0 ? "None of their scripts could be added to your sample." : `${scripts(added)} added to your sample.` };
}

/** "Change a final mark": the changed marks (each a mark or NR) of a checked script, with a reason; a marker's own marks
 * never change. acceptFirst: the open review of a paused marker's script, which is not checked yet: it is accepted
 * first, with the same reason, and then the marks are changed. */
export async function setFinalMarks(unitId: string, marks: MarkInput[], reason: string, acceptFirst?: string): Promise<ReviewActionResult> {
  await requireStaff(MARKING_ROLES);
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  if (!isUuid(unitId) || !goodMarks(marks) || (acceptFirst !== undefined && !isUuid(acceptFirst))) return { ok: false, message: INVALID };
  if (acceptFirst !== undefined) {
    const accepted = await call("marking_review_accept", { p_review: acceptFirst, p_reason: reason.trim() });
    if (accepted?.ok !== true) return reviewRefusal(accepted);
  }
  const a = await call("marking_final_set", { p_unit: unitId, p_marks: cleanMarks(marks), p_reason: reason.trim() });
  if (a?.ok !== true) {
    const r = reviewRefusal(a);
    return acceptFirst === undefined ? r : { ok: false, message: `The script was accepted, but the mark was not changed. ${r.message}` };
  }
  return { ok: true, message: typeof a.total === "number" ? `Final marks changed. The total is now ${formatMark(a.total)}.` : "Final marks changed." };
}

/** Clears a marker for live marking on the exam after their practice (it also ends a pause), with a reason. */
export async function clearMarker(examId: string, markerId: string, reason: string): Promise<ReviewActionResult> {
  await requireStaff(MARKING_ROLES);
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  if (!isUuid(examId) || !isUuid(markerId)) return { ok: false, message: INVALID };
  const a = await call("marking_marker_clear", { p_exam: examId, p_marker: markerId, p_reason: reason.trim() });
  return a?.ok === true ? { ok: true, message: "Cleared for live marking." } : standardRefusal(a);
}

/** Pauses a marker on the exam, with a reason: Next script gives them nothing, and their submitted scripts come to the
 * lead marker. */
export async function pauseMarker(examId: string, markerId: string, reason: string): Promise<ReviewActionResult> {
  await requireStaff(MARKING_ROLES);
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  if (!isUuid(examId) || !isUuid(markerId)) return { ok: false, message: INVALID };
  const a = await call("marking_marker_pause", { p_exam: examId, p_marker: markerId, p_reason: reason.trim() });
  return a?.ok === true ? { ok: true, message: "Paused." } : standardRefusal(a);
}

/** The lead uses a script they marked themselves for practice or as a seeded script, with an optional note to the
 * markers ("Why these marks", 3 to 1,000 characters: checked here, as the database says only that it is not valid). */
export async function setStandard(unitId: string, use: string, note?: string): Promise<ReviewActionResult> {
  await requireStaff(MARKING_ROLES);
  const noteBad = noteProblem(note ?? "", false);
  if (noteBad) return { ok: false, message: noteBad };
  if (!isUuid(unitId) || (use !== "practice" && use !== "seed")) return { ok: false, message: standardMessageFor("invalid_input") };
  const a = await call("marking_standard_set", { p_unit: unitId, p_use: use, p_note: (note ?? "").trim() || null });
  if (a?.ok !== true) return standardRefusal(a);
  return { ok: true, message: use === "practice" ? "Used for practice." : "Used as a seeded script." };
}

/** Stops using a practice or seeded script, with a reason. Attempts already submitted stand. */
export async function retireStandard(standardId: string, reason: string): Promise<ReviewActionResult> {
  await requireStaff(MARKING_ROLES);
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  if (!isUuid(standardId)) return { ok: false, message: standardMessageFor("invalid_input") };
  const a = await call("marking_standard_retire", { p_standard: standardId, p_reason: reason.trim() });
  return a?.ok === true ? { ok: true, message: "No longer used." } : standardRefusal(a);
}
