"use server";

import { revalidatePath } from "next/cache";
import { markerMessageFor } from "@stem/shared";
import { reasonProblem } from "@/lib/exception-queue";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

/** What these actions send back; they never throw for expected failures. */
export type MarkerActionResult = { ok: true; message: string; alreadyMarked?: number } | { ok: false; message: string };
export type CandidateHit = { id: string; indexNumber: string | null; name: string | null };

const GENERIC = markerMessageFor("internal");
const PATH = "/admin/marking/markers";

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;
type Answer = Record<string, unknown>;

const isSubject = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v > 0;

/** Calls one marker function with the reason; the database checks every rule again. */
async function call(fn: string, args: Record<string, unknown>, reason: string, done: (a: Answer) => MarkerActionResult): Promise<MarkerActionResult> {
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  const supabase = await createClient();
  const { data, error } = await (supabase.rpc as unknown as Rpc)(fn, { ...args, p_reason: reason.trim() });
  revalidatePath(PATH);
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, message: GENERIC };
  const a = data as Answer;
  return a.ok === true ? done(a) : { ok: false, message: markerMessageFor(typeof a.code === "string" ? a.code : null) };
}

export async function approveMarkerAction(marker: string, subject: number, reason: string): Promise<MarkerActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(marker) || !isSubject(subject)) return { ok: false, message: GENERIC };
  return call("marker_approve", { p_marker: marker, p_subject: subject }, reason, () => ({ ok: true, message: "Approved to mark this subject." }));
}

export async function unapproveMarkerAction(marker: string, subject: number, reason: string): Promise<MarkerActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(marker) || !isSubject(subject)) return { ok: false, message: GENERIC };
  return call("marker_unapprove", { p_marker: marker, p_subject: subject }, reason, (a) => {
    const n = typeof a.released === "number" ? a.released : 0;
    return { ok: true, message: n > 0 ? `Approval removed. ${n} ${n === 1 ? "script they were marking is" : "scripts they were marking are"} free for others.` : "Approval removed." };
  });
}

/** marker null removes the subject's lead marker. */
export async function setLeadMarkerAction(subject: number, marker: string | null, reason: string): Promise<MarkerActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isSubject(subject) || (marker !== null && !isUuid(marker))) return { ok: false, message: GENERIC };
  return call("marker_set_lead", { p_subject: subject, p_marker: marker }, reason, () => ({ ok: true, message: marker ? "Lead marker set." : "Lead marker removed." }));
}

export async function setConflictAction(marker: string, student: string, note: string, reason: string): Promise<MarkerActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(marker) || !isUuid(student)) return { ok: false, message: GENERIC };
  if ((note ?? "").trim().length > 300) return { ok: false, message: "Keep the note to 300 characters." };
  return call("marker_conflict_set", { p_marker: marker, p_student: student, p_note: (note ?? "").trim() }, reason, (a) => {
    const marked = typeof a.already_marked === "number" ? a.already_marked : 0;
    return {
      ok: true,
      alreadyMarked: marked,
      message:
        marked > 0
          ? `Conflict added. This marker has already marked ${marked} of this candidate's scripts. Take them back on the Marking page if they should be marked again.`
          : "Conflict added.",
    };
  });
}

export async function removeConflictAction(marker: string, student: string, reason: string): Promise<MarkerActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(marker) || !isUuid(student)) return { ok: false, message: GENERIC };
  return call("marker_conflict_remove", { p_marker: marker, p_student: student }, reason, () => ({ ok: true, message: "Conflict removed." }));
}

/** Students whose index number or name contains the search, at most 20. */
export async function findConflictCandidatesAction(query: string): Promise<{ ok: true; candidates: CandidateHit[] } | { ok: false; message: string }> {
  await requireStaff(["admin", "owner"]);
  const q = (query ?? "").trim().slice(0, 40);
  if (q.replace(/[^0-9a-z]/gi, "").length < 2) return { ok: false, message: "Type at least two characters of the index number or name." };
  const supabase = await createClient();
  const { data, error } = await (supabase.rpc as unknown as Rpc)("marker_conflict_candidates", { p_query: q });
  const a = data as Answer | null;
  if (error || !a || a.ok !== true || !Array.isArray(a.candidates)) return { ok: false, message: GENERIC };
  const candidates = (a.candidates as Record<string, unknown>[])
    .filter((c) => isUuid(c.id))
    .map((c) => ({
      id: c.id as string,
      indexNumber: typeof c.index_number === "string" ? c.index_number : null,
      name: typeof c.name === "string" ? c.name : null,
    }));
  return { ok: true, candidates };
}
