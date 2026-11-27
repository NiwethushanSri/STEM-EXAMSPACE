"use server";

import { revalidatePath } from "next/cache";
import { boundariesMessageFor, resultsMessageFor } from "@stem/shared";
import { reasonProblem } from "@/lib/exception-queue";
import { parseExport, publishAtCheck, resultsCsv, validateBoundaries, type BoundaryInput, type GradeCount } from "@/lib/results-admin";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

/** What these actions send back; they never throw for expected failures. The message is the shared one for the code the
 * database refused with. */
export type ResultsActionResult = { ok: true; message: string } | { ok: false; message: string };
export type PreviewResult = { ok: true; grades: GradeCount[]; below: { all: number; centre: number; home: number } } | { ok: false; message: string };
export type CsvResult = { ok: true; filename: string; csv: string } | { ok: false; message: string };

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;
type Answer = Record<string, unknown>;

const GENERIC = resultsMessageFor("internal");

/** Calls one results function as the signed-in admin (the database checks the admin and every rule again). Null when the
 * call failed or its answer is not an object. */
async function call(fn: string, args: Record<string, unknown>): Promise<Answer | null> {
  const supabase = await createClient();
  const { data, error } = await (supabase.rpc as unknown as Rpc)(fn, args);
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return null;
  return data as Answer;
}

const codeOf = (a: Answer) => (typeof a.code === "string" ? a.code : null);

function refresh(examId: string) {
  revalidatePath(`/admin/results/${examId}`);
  revalidatePath("/admin/results");
}

/** Runs a function whose refusal is one of the results codes; a success says `done`. */
async function run(examId: string, fn: string, args: Record<string, unknown>, done: (a: Answer) => string): Promise<ResultsActionResult> {
  const a = await call(fn, { ...args });
  refresh(examId);
  if (!a) return { ok: false, message: GENERIC };
  if (a.ok === true) return { ok: true, message: done(a) };
  return { ok: false, message: resultsMessageFor(codeOf(a), typeof a.count === "number" ? a.count : null) };
}

/** Prepares the exam's results from its final marks. */
export async function prepareResults(examId: string): Promise<ResultsActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  return run(examId, "results_prepare", { p_exam: examId }, () => "The results are prepared. Check the totals below.");
}

/** What the boundaries would give, without saving them. */
export async function previewBoundaries(examId: string, rows: BoundaryInput[], maxTotal: number | null): Promise<PreviewResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  const checked = validateBoundaries(rows, maxTotal);
  if (!checked.ok) return { ok: false, message: checked.message };
  if (checked.grades.length === 0) return { ok: false, message: "Add at least one grade to preview." };
  const a = await call("grade_boundaries_preview", { p_exam: examId, p_grades: checked.grades });
  if (!a) return { ok: false, message: GENERIC };
  if (a.ok !== true) return { ok: false, message: boundariesMessageFor(codeOf(a)) };
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
  const grades = (Array.isArray(a.grades) ? a.grades : []).flatMap((g): GradeCount[] => {
    const o = g && typeof g === "object" ? (g as Answer) : null;
    return o && typeof o.grade === "string" ? [{ grade: o.grade, all: num(o.all), centre: num(o.centre), home: num(o.home) }] : [];
  });
  const b = a.below && typeof a.below === "object" ? (a.below as Answer) : {};
  return { ok: true, grades, below: { all: num(b.all), centre: num(b.centre), home: num(b.home) } };
}

/** Saves the boundaries (an empty list clears them), with an optional reason (3 to 300 characters). */
export async function saveBoundaries(examId: string, rows: BoundaryInput[], maxTotal: number | null, reason: string): Promise<ResultsActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  const checked = validateBoundaries(rows, maxTotal);
  if (!checked.ok) return { ok: false, message: checked.message };
  const problem = reasonProblem(reason ?? "", false);
  if (problem) return { ok: false, message: problem };
  const text = (reason ?? "").trim();
  const a = await call("grade_boundaries_set", { p_exam: examId, p_grades: checked.grades, ...(text ? { p_reason: text } : {}) });
  refresh(examId);
  if (!a) return { ok: false, message: GENERIC };
  if (a.ok !== true) return { ok: false, message: boundariesMessageFor(codeOf(a)) };
  return { ok: true, message: checked.grades.length === 0 ? "The grade boundaries are cleared." : "The grade boundaries are saved." };
}

const STATUSES = ["absent", "incomplete", "disqualified", "auto"] as const;
export type SettableStatus = (typeof STATUSES)[number];

/** Sets one candidate's status (auto hands it back to the register and the script), with a reason of 3 to 300
 * characters. After publication this is a correction of that one row. */
export async function setResultStatus(examId: string, bookingId: string, status: string, reason: string): Promise<ResultsActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId) || !isUuid(bookingId) || !STATUSES.includes(status as SettableStatus)) return { ok: false, message: GENERIC };
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  return run(examId, "result_status_set", { p_booking: bookingId, p_status: status, p_reason: reason.trim() }, () => "The status is set.");
}

/** Signs the results off and publishes them, now (no date) or at a UK time. `version` is the one the page showed: a
 * change made since is refused as "The results changed since you checked them." */
export async function signOffAndPublish(examId: string, version: number, date: string, time: string): Promise<ResultsActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId) || !Number.isSafeInteger(version) || version < 0) return { ok: false, message: GENERIC };
  const when = publishAtCheck(date ?? "", time ?? "", Date.now());
  if (!when.ok) return { ok: false, message: when.message };
  return run(examId, "results_publish", { p_exam: examId, p_version: version, ...(when.at ? { p_at: when.at } : {}) }, (a) =>
    a.state === "scheduled" ? "The results are signed off and will publish at the time you chose." : "The results are signed off and published.",
  );
}

/** Cancels a scheduled publication; the results go back to prepared. */
export async function cancelPublication(examId: string): Promise<ResultsActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  return run(examId, "results_publish_cancel", { p_exam: examId }, (a) =>
    a.already === true ? "Nothing was scheduled." : "The scheduled publication is cancelled.",
  );
}

/** Withdraws published results, with a reason of 3 to 300 characters. */
export async function withdrawResults(examId: string, reason: string): Promise<ResultsActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  return run(examId, "results_withdraw", { p_exam: examId, p_reason: reason.trim() }, (a) =>
    a.already === true ? "These results were already withdrawn." : "The results are withdrawn. Families can no longer see them.",
  );
}

/** The results as a CSV. results_export records the download (its audit row is written in the same call), and the file
 * is given only when that call succeeded, so no file leaves without its record (Ruling R26). */
export async function exportResultsCsv(examId: string): Promise<CsvResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  const a = await call("results_export", { p_exam: examId });
  if (!a) return { ok: false, message: GENERIC };
  if (a.ok !== true) return { ok: false, message: resultsMessageFor(codeOf(a)) };
  const parsed = parseExport(a);
  if (!parsed) return { ok: false, message: GENERIC };
  return { ok: true, filename: parsed.filename, csv: resultsCsv(parsed.rows) };
}
