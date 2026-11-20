"use server";

import { revalidatePath } from "next/cache";
import { exceptionMessageFor, normaliseIndexNumber } from "@stem/shared";
import { escapeLike } from "@/lib/booking-search";
import { conflictMessage, reasonProblem, reasonRequired, rpcFor, type QueueArea, type ResolveInput } from "@/lib/exception-queue";
import { MAX_AREAS_PER_PAGE } from "@/lib/hidden-areas";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

/** What these actions send back; they never throw for expected failures. */
export type QueueActionResult = { ok: true; message: string } | { ok: false; message: string };

const GENERIC = "Something went wrong. Please try again.";
const PATH = "/admin/scripts/exceptions";

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;
type Answer = { ok?: unknown; code?: unknown; resolved_by?: unknown; resolved_at?: unknown } & Record<string, unknown>;

function done(input: ResolveInput, a: Answer): string {
  switch (input.action) {
    case "assign":
      return a.replaced_page_id ? "Assigned. The page is in the candidate's script, in place of the page that was there." : "Assigned. The page is in the candidate's script.";
    case "blank":
      return "Marked as blank. The page is set aside.";
    case "keep_existing":
      return "Kept the page already chosen.";
    case "reject":
      return a.submission_rejected === true ? "Rejected. The family has been emailed with your reason." : "Rejected. The page is set aside.";
    case "confirm":
      return "Confirmed.";
    case "dismiss_missing":
      return a.state === "resolved" ? "Confirmed as left blank." : "Saved. Some pages are still missing.";
    case "late_accept":
      return "The late script will be marked.";
    case "late_reject":
      return "The late script will not be marked. The family has been emailed with your reason.";
  }
}

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
  if (a.ok === true) return { ok: true, message: done(input, a) };
  if (a.code === "conflict") return { ok: false, message: conflictMessage(a) };
  return { ok: false, message: exceptionMessageFor(typeof a.code === "string" ? a.code : null) };
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
  return { ok: false, message: exceptionMessageFor(typeof a.code === "string" ? a.code : null) };
}

/** A candidate of the exam that "Assign" can choose. */
export type CandidateOption = {
  bookingId: string;
  name: string;
  indexNumber: string | null;
  sitting: string;
  status: string;
  /** Present, late or absent on the register (centre candidates), or null. */
  attendance: string | null;
  scriptNumber: string | null;
  /** The copy pages their script shows now. */
  pages: number[];
  /** How many pages their copy has (the pages a page can be assigned to). */
  copyPages: number | null;
};

type Embedded<T> = T | T[] | null;
const one = <T,>(v: Embedded<T>): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));

/** The exam's candidates whose index number contains the search (as typed, or in the SE-yyyy-nnnn form), at most 10. */
export async function findCandidatesAction(examId: string, query: string): Promise<{ ok: true; candidates: CandidateOption[] } | { ok: false; message: string }> {
  await requireStaff(["admin", "owner"]);
  const q = (query ?? "").trim().slice(0, 40);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  if (q.replace(/[\s-]/g, "").length < 2) return { ok: false, message: "Type at least two characters of the index number." };
  const supabase = await createClient();
  const forms = [...new Set([q.toUpperCase(), normaliseIndexNumber(q)])];
  const found = await Promise.all(
    forms.map((f) => supabase.from("student_details").select("profile_id").ilike("index_number", `%${escapeLike(f)}%`).limit(50)),
  );
  if (found.some((r) => r.error)) return { ok: false, message: GENERIC };
  const studentIds = [...new Set(found.flatMap((r) => (r.data ?? []).map((d) => d.profile_id)))];
  if (studentIds.length === 0) return { ok: true, candidates: [] };

  const { data: rows, error } = await supabase
    .from("bookings")
    .select("id, sitting, status, student_id, student:profiles!bookings_student_id_fkey(first_name, last_name, student_details!profile_id(index_number))")
    .eq("exam_id", examId)
    .in("student_id", studentIds)
    .order("id")
    .limit(10);
  if (error) return { ok: false, message: GENERIC };
  type Row = {
    id: string;
    sitting: string;
    status: string;
    student_id: string | null;
    student: Embedded<{ first_name: string; last_name: string; student_details: Embedded<{ index_number: string | null }> }>;
  };
  const bookings = (rows ?? []) as unknown as Row[];
  if (bookings.length === 0) return { ok: true, candidates: [] };
  const bookingIds = bookings.map((b) => b.id);

  const [att, scripts, copies] = await Promise.all([
    supabase.from("attendance").select("student_id, status").eq("exam_id", examId).in("student_id", bookings.map((b) => b.student_id).filter((s): s is string => !!s)),
    supabase.from("scripts").select("id, booking_id, number, version").in("booking_id", bookingIds),
    supabase.from("paper_copies").select("booking_id, page_count, created_at").in("booking_id", bookingIds).order("created_at", { ascending: false }),
  ]);
  if (att.error || scripts.error || copies.error) return { ok: false, message: GENERIC };
  const scriptRows = scripts.data ?? [];
  const links = scriptRows.length
    ? await supabase.from("script_page_links").select("script_id, version, copy_page").in("script_id", scriptRows.map((s) => s.id))
    : { data: [], error: null };
  if (links.error) return { ok: false, message: GENERIC };

  const candidates = bookings.map((b): CandidateOption => {
    const st = one(b.student);
    const script = scriptRows.find((s) => s.booking_id === b.id) ?? null;
    return {
      bookingId: b.id,
      name: st ? `${st.first_name} ${st.last_name}`.trim() || "No name" : "Removed account",
      indexNumber: st ? (one(st.student_details)?.index_number ?? null) : null,
      sitting: b.sitting,
      status: b.status,
      attendance: (att.data ?? []).find((a) => a.student_id === b.student_id)?.status ?? null,
      scriptNumber: script?.number ?? null,
      pages: script
        ? (links.data ?? []).filter((l) => l.script_id === script.id && l.version === script.version).map((l) => l.copy_page).sort((x, y) => x - y)
        : [],
      copyPages: (copies.data ?? []).find((c) => c.booking_id === b.id)?.page_count ?? null,
    };
  });
  return { ok: true, candidates };
}
