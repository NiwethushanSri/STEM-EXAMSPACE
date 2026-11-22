"use server";

import { revalidatePath } from "next/cache";
import { exceptionMessageFor } from "@stem/shared";
import {
  failureMessage,
  markingCheckedMessage,
  markingCheckFailure,
  NAME_SHOWS_MESSAGE,
  parseCandidates,
  reasonProblem,
  reasonRequired,
  resolvedMessage,
  rpcFor,
  type CandidateOption,
  type QueueArea,
  type ResolveInput,
} from "@/lib/exception-queue";
import { MAX_AREAS_PER_PAGE } from "@/lib/hidden-areas";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

/** What these actions send back; they never throw for expected failures. */
export type QueueActionResult = { ok: true; message: string } | { ok: false; message: string };

const GENERIC = "Something went wrong. Please try again.";
const PATH = "/admin/scripts/exceptions";

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;
type Answer = Record<string, unknown>;

/** Resolves an exception (or decides on a late script) with the reason; the database checks every rule again. */
export async function resolveExceptionAction(input: ResolveInput): Promise<QueueActionResult> {
  await requireStaff(["admin", "owner"]);
  const ids = "scriptId" in input ? [input.scriptId] : [input.exceptionId];
  if (input.action === "assign") ids.push(input.bookingId);
  if (!ids.every(isUuid)) return { ok: false, message: GENERIC };
  if (input.action === "assign" && !(Number.isInteger(input.copyPage) && input.copyPage > 0)) return { ok: false, message: exceptionMessageFor("invalid_input") };
  if (input.action === "dismiss_missing" && !(input.pages.length > 0 && input.pages.every((n) => Number.isInteger(n) && n > 0))) {
    return { ok: false, message: "Choose the pages that were left blank." };
  }
  const problem = reasonProblem(input.reason ?? "", reasonRequired(input.action));
  if (problem) return { ok: false, message: problem };

  const { fn, args } = rpcFor(input);
  const supabase = await createClient();
  const { data, error } = await (supabase.rpc as unknown as Rpc)(fn, args);
  revalidatePath(PATH);
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, message: GENERIC };
  const a = data as Answer;
  return a.ok === true ? { ok: true, message: resolvedMessage(input, a) } : { ok: false, message: failureMessage(a) };
}

/** Replaces the staff hidden areas of one page (fractions of its full picture), with the reason. */
export async function saveHiddenAreasAction(pageId: string, areas: QueueArea[], reason: string): Promise<QueueActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(pageId) || !Array.isArray(areas) || areas.length > MAX_AREAS_PER_PAGE) return { ok: false, message: exceptionMessageFor("invalid_input") };
  const problem = reasonProblem(reason, true);
  if (problem) return { ok: false, message: problem };
  const clean = areas.map(({ x, y, w, h }) => ({ x, y, w, h }));
  if (!clean.every((a) => [a.x, a.y, a.w, a.h].every((n) => typeof n === "number" && Number.isFinite(n)))) {
    return { ok: false, message: exceptionMessageFor("invalid_input") };
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("script_page_set_hidden_areas", { p_page: pageId, p_areas: clean, p_reason: reason.trim() });
  revalidatePath(PATH);
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, message: GENERIC };
  const a = data as Answer;
  if (a.ok === true) return { ok: true, message: clean.length ? "Hidden areas saved." : "Hidden areas removed." };
  return { ok: false, message: failureMessage(a) };
}

/** "The name is hidden": staff checked this marking picture of the page (the one they were shown). */
export async function markingCheckedAction(pageId: string, markingPath: string): Promise<QueueActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(pageId) || typeof markingPath !== "string" || markingPath.trim() === "" || markingPath.length > 1000) return { ok: false, message: GENERIC };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("script_page_marking_checked", { p_page: pageId, p_marking_path: markingPath });
  revalidatePath(PATH);
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, message: GENERIC };
  const a = data as Answer;
  return a.ok === true ? { ok: true, message: markingCheckedMessage(a.script_state) } : { ok: false, message: markingCheckFailure(a) };
}

/** "A name still shows": the page goes back to "Hide the name", with the reason. */
export async function markingNameShowsAction(pageId: string, reason: string): Promise<QueueActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(pageId) || typeof reason !== "string") return { ok: false, message: GENERIC };
  const problem = reasonProblem(reason, true);
  if (problem) return { ok: false, message: problem };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("script_page_marking_name_shows", { p_page: pageId, p_reason: reason.trim() });
  revalidatePath(PATH);
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, message: GENERIC };
  const a = data as Answer;
  return a.ok === true ? { ok: true, message: NAME_SHOWS_MESSAGE } : { ok: false, message: markingCheckFailure(a) };
}

/** The exam's candidates whose index number contains the search (spaces, hyphens and case ignored), at most 10. The
 * database filters by the exam before the limit (script_exception_candidates). */
export async function findCandidatesAction(examId: string, query: string): Promise<{ ok: true; candidates: CandidateOption[] } | { ok: false; message: string }> {
  await requireStaff(["admin", "owner"]);
  const q = (query ?? "").trim().slice(0, 40);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  if (q.replace(/[^0-9a-z]/gi, "").length < 2) return { ok: false, message: "Type at least two characters of the index number." };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("script_exception_candidates", { p_exam: examId, p_query: q });
  const candidates = error ? null : parseCandidates(data);
  return candidates ? { ok: true, candidates } : { ok: false, message: GENERIC };
}
