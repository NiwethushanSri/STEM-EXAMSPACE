"use server";

import { revalidatePath } from "next/cache";
import { alertMessageFor, allocationMessageFor } from "@stem/shared";
import { reasonProblem } from "@/lib/exception-queue";
import { MARKING_ROLES } from "@/lib/marking-lists";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

/** What these actions send back; they never throw for expected failures. */
export type MarkingActionResult = { ok: true; message: string } | { ok: false; message: string };
export type NextScriptResult = { ok: true; unitId: string } | { ok: false; message: string };

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;
type Answer = Record<string, unknown>;

const MARKER_GENERIC = allocationMessageFor("internal", "marker");
const ALERT_GENERIC = alertMessageFor("internal");

/** Calls one function; null when the database could not answer. */
async function call(fn: string, args: Record<string, unknown>): Promise<Answer | null> {
  const supabase = await createClient();
  const { data, error } = await (supabase.rpc as unknown as Rpc)(fn, args);
  revalidatePath("/marking");
  revalidatePath("/admin/marking");
  return error || !data || typeof data !== "object" || Array.isArray(data) ? null : (data as Answer);
}

const code = (a: Answer) => (typeof a.code === "string" ? a.code : null);
const count = (v: unknown) => (typeof v === "number" && Number.isSafeInteger(v) ? v : 0);

/** "Next script": the piece to open (one the marker holds, their marking in progress, or a free one). groupId: a
 * question group of an exam marked by question. */
export async function nextScript(examId: string, groupId?: string | null): Promise<NextScriptResult> {
  await requireStaff(MARKING_ROLES);
  if (!isUuid(examId) || (groupId != null && !isUuid(groupId))) return { ok: false, message: allocationMessageFor("invalid_input", "marker") };
  const a = await call("marking_next", { p_exam: examId, p_group: groupId ?? null });
  if (!a) return { ok: false, message: MARKER_GENERIC };
  if (a.ok === true && isUuid(a.unit_id)) return { ok: true, unitId: a.unit_id };
  return { ok: false, message: allocationMessageFor(code(a), "marker") };
}

/** The marker gives a piece back. The reason is optional; given, it is 3 to 300 characters. */
export async function giveBack(unitId: string, reason?: string): Promise<MarkingActionResult> {
  await requireStaff(MARKING_ROLES);
  if (!isUuid(unitId)) return { ok: false, message: allocationMessageFor("invalid_input", "marker") };
  const problem = reasonProblem(reason ?? "", false);
  if (problem) return { ok: false, message: problem };
  const a = await call("marking_give_back", { p_unit: unitId, p_reason: (reason ?? "").trim() || null });
  if (!a) return { ok: false, message: MARKER_GENERIC };
  return a.ok === true ? { ok: true, message: "Script given back." } : { ok: false, message: allocationMessageFor(code(a), "marker") };
}

/** Runs one alert function with a reason (3 to 300 characters); the database checks the lead or admin again. */
async function alertCall(fn: string, args: Record<string, unknown>, reason: string, done: (a: Answer) => string): Promise<MarkingActionResult> {
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  const a = await call(fn, { ...args, p_reason: reason.trim() });
  if (!a) return { ok: false, message: ALERT_GENERIC };
  if (a.ok === true) return { ok: true, message: done(a) };
  return { ok: false, message: alertMessageFor(code(a), typeof a.reason === "string" ? a.reason : null) };
}

/** The lead or an admin releases a changed picture's hold: the markers carry on. */
export async function releaseAlert(alertId: string, reason: string): Promise<MarkingActionResult> {
  await requireStaff(MARKING_ROLES);
  if (!isUuid(alertId)) return { ok: false, message: alertMessageFor("invalid_input") };
  return alertCall("marking_alert_release", { p_alert: alertId }, reason, () => "Released. The markers can carry on.");
}

/** The lead or an admin notes a pages alert (pages set aside, pages changed). */
export async function noteAlert(alertId: string, reason: string): Promise<MarkingActionResult> {
  await requireStaff(MARKING_ROLES);
  if (!isUuid(alertId)) return { ok: false, message: alertMessageFor("invalid_input") };
  return alertCall("marking_alert_note", { p_alert: alertId }, reason, () => "Noted.");
}

/** The lead or an admin releases every changed-picture alert of an exam that can be released now. */
export async function releaseAllAlerts(examId: string, reason: string): Promise<MarkingActionResult> {
  await requireStaff(MARKING_ROLES);
  if (!isUuid(examId)) return { ok: false, message: alertMessageFor("invalid_input") };
  return alertCall("marking_alerts_release_all", { p_exam: examId }, reason, (a) => {
    const n = count(a.released);
    const blocked = count(a.blocked);
    const done = n === 0 ? "No alert could be released yet." : `${n} ${n === 1 ? "alert" : "alerts"} released.`;
    if (blocked === 0) return done;
    return `${done} ${blocked} ${blocked === 1 ? "was left because you cannot mark its candidate" : "were left because you cannot mark their candidates"}.`;
  });
}
