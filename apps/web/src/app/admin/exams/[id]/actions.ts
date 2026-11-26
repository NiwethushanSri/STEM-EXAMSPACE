"use server";

import { revalidatePath } from "next/cache";
import { markingMessageFor } from "@stem/shared";
import { checksProblem, type CheckSettings } from "@/lib/exam-marking";
import { reasonProblem } from "@/lib/exception-queue";
import type { FileBegun, StructurePayload, StructureResult } from "@/lib/exam-structure";
import { beginMarkSchemeFile, markSchemeFileStored, removeMarkSchemeFile, saveStructure } from "@/lib/exam-structure-server";
import { londonLocalToUtc } from "@/lib/london-time";
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
    case "roles_not_reviewed":
      return { ok: false, message: ROLES_NOT_REVIEWED };
    case "not_found":
      return { ok: false, message: "That could not be found. Refresh the page and try again." };
    case "forbidden":
      return { ok: false, message: "You do not have permission to do this." };
    default:
      return { ok: false, message: GENERIC };
  }
}

/** The database refuses to release a paper whose page roles were never checked (Ruling R40). */
const ROLES_NOT_REVIEWED =
  'Check the page roles first: under "Page roles and hidden areas" on this page, set each page (answer, cover, blank or information) and save. Then release the paper.';

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

type Rpc = { data: unknown; error: unknown };
const codeOf = (r: Rpc) =>
  !r.error && r.data && typeof r.data === "object" && !Array.isArray(r.data) ? (r.data as { ok?: unknown; code?: unknown; pages?: unknown; reviewed_at?: unknown }) : null;

/** Whether these roles are the ones saved (paper_page_layout's answer) and were already checked. */
function rolesUnchanged(saved: ReturnType<typeof codeOf>, roles: { page: number; role: string }[]): boolean {
  if (saved?.ok !== true || !saved.reviewed_at || !Array.isArray(saved.pages)) return false;
  const byPage = new Map(
    saved.pages.flatMap((p: unknown) => {
      const r = p as { page?: unknown; role?: unknown };
      return typeof r?.page === "number" && typeof r.role === "string" ? [[r.page, r.role] as const] : [];
    }),
  );
  return byPage.size === roles.length && roles.every((r) => byPage.get(r.page) === r.role);
}

/**
 * Saves the page roles and the hidden areas of a paper version, each through its own database function (both are
 * admin only and re-check everything). The roles lock once scripts have come in; the areas can still change then.
 * `changedPages` are the pages whose areas changed.
 */
export async function savePageLayoutAction(
  examId: string,
  paperId: string,
  roles: { page: number; role: string }[],
  areas: { page: number; x: number; y: number; w: number; h: number }[],
): Promise<PaperActionResult & { changedPages?: number[] }> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId) || !isUuid(paperId) || !Array.isArray(roles) || !Array.isArray(areas)) return { ok: false, message: GENERIC };
  const supabase = await createClient();
  // The roles are sent only when they change (or are confirmed for the first time): once scripts exist they are
  // locked, and an areas-only save must still go through.
  const saved = codeOf(await supabase.rpc("paper_page_layout", { p_paper: paperId }));
  const rolesRes = rolesUnchanged(saved, roles)
    ? { data: { ok: true }, error: null }
    : await supabase.rpc("set_paper_page_roles", { p_paper: paperId, p_roles: roles });
  const areasRes = await supabase.rpc("set_paper_hidden_areas", { p_paper: paperId, p_areas: areas });
  refresh(examId);
  const r = codeOf(rolesRes);
  const a = codeOf(areasRes);
  if (r?.ok === true && a?.ok === true) {
    const changed = (areasRes.data as { changed_pages?: unknown }).changed_pages;
    return { ok: true, message: "Page roles and hidden areas saved.", changedPages: Array.isArray(changed) ? changed.filter((n): n is number => typeof n === "number") : [] };
  }
  if (r?.code === "conflict") {
    return { ok: false, message: ROLES_LOCKED + (a?.ok === true ? " The hidden areas were saved." : "") };
  }
  return answer(r?.ok === true ? areasRes.data : rolesRes.data, r?.ok === true ? areasRes.error : rolesRes.error, ROLES_LOCKED, "");
}

const ROLES_LOCKED = "Scripts have already come in for this paper, so the page roles can no longer change.";

/** Saves the exam's questions and mark scheme. Once marking has opened a change needs a reason and is recorded. */
export async function saveStructureAction(examId: string, structure: StructurePayload, reason?: string): Promise<StructureResult> {
  await requireStaff(["admin", "owner"]);
  return saveStructure(examId, structure, reason);
}

/** Starts a mark scheme PDF upload: the path the browser sends it to. */
export async function markSchemeBeginAction(examId: string, bytes: number): Promise<FileBegun> {
  await requireStaff(["admin", "owner"]);
  return beginMarkSchemeFile(examId, bytes);
}

/** The uploaded PDF becomes the exam's mark scheme. */
export async function markSchemeStoredAction(examId: string, fileId: string): Promise<{ ok: boolean; code?: string }> {
  await requireStaff(["admin", "owner"]);
  return markSchemeFileStored(examId, fileId);
}

/** Removes the mark scheme PDF, with a reason. */
export async function markSchemeRemoveAction(examId: string, fileId: string, reason: string): Promise<StructureResult> {
  await requireStaff(["admin", "owner"]);
  return removeMarkSchemeFile(examId, fileId, reason);
}

/** What the marking actions send back. reasonRequired: a deadline change after marking has opened needs a reason. */
export type MarkingActionResult = { ok: true; message: string } | { ok: false; message: string; reasonRequired?: boolean };

type LooseRpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;

/** Calls one marking function (the database checks every rule again); done words a successful answer, and `words`
 * replaces the usual message for a code where this function means something else by it. */
async function callMarking(
  examId: string,
  fn: string,
  args: Record<string, unknown>,
  done: (answer: Record<string, unknown>) => string,
  words: Record<string, string> = {},
): Promise<MarkingActionResult> {
  const supabase = await createClient();
  // p_deadline may be null (no deadline), which the generated argument types do not allow.
  const { data, error } = await (supabase.rpc as unknown as LooseRpc)(fn, { p_exam: examId, ...args });
  refresh(examId);
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, message: GENERIC };
  const a = data as Record<string, unknown>;
  if (a.ok === true) return { ok: true, message: done(a) };
  const code = typeof a.code === "string" ? a.code : null;
  const message = code && Object.hasOwn(words, code) ? words[code] : markingMessageFor(code);
  return code === "reason_required" ? { ok: false, message, reasonRequired: true } : { ok: false, message };
}

const readyLine = (n: unknown) => (n === 1 ? "1 script is ready to mark." : `${typeof n === "number" ? n : 0} scripts are ready to mark.`);

/** How the exam is marked, and its marking deadline as a UK date and time (both empty: no deadline). Once marking has
 * opened the mode is fixed and a deadline change needs a reason. */
export async function saveMarkingSettingsAction(
  examId: string,
  settings: { mode: string; deadlineDate: string; deadlineTime: string; reason?: string },
): Promise<MarkingActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId) || (settings?.mode !== "whole" && settings?.mode !== "by_question")) return { ok: false, message: GENERIC };
  const date = (settings.deadlineDate ?? "").trim();
  const time = (settings.deadlineTime ?? "").trim();
  const deadline = date || time ? londonLocalToUtc(date, time) : null;
  if ((date || time) && !deadline) return { ok: false, message: "Enter the deadline as a date and a time." };
  const reason = (settings.reason ?? "").trim();
  const problem = reasonProblem(reason, false);
  if (problem) return { ok: false, message: problem, reasonRequired: true };
  return callMarking(examId, "marking_settings_set", { p_mode: settings.mode, p_deadline: deadline, p_reason: reason || null }, () => "Marking settings saved.");
}

/** The checks on the marking: double marking (the share second-marked, and the difference that goes to the lead
 * marker), seeded scripts and practice. Turning one off needs a reason and a subject with one approved marker; once
 * marking has opened any change needs a reason. */
export async function saveChecksAction(examId: string, settings: CheckSettings, reason?: string): Promise<MarkingActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId) || !settings || typeof settings !== "object") return { ok: false, message: GENERIC };
  const { doubleMarking, samplePercent, tolerancePercent, seeds, seedEvery, practice } = settings;
  if (typeof doubleMarking !== "boolean" || typeof seeds !== "boolean" || typeof practice !== "boolean") return { ok: false, message: GENERIC };
  const problem = checksProblem(settings);
  if (problem) return { ok: false, message: problem };
  const why = (reason ?? "").trim();
  const reasonBad = reasonProblem(why, false);
  if (reasonBad) return { ok: false, message: reasonBad, reasonRequired: true };
  return callMarking(
    examId,
    "marking_checks_set",
    {
      p_settings: {
        double_marking: doubleMarking,
        sample_percent: samplePercent,
        tolerance_percent: tolerancePercent,
        seeds,
        seed_every: seedEvery,
        practice,
      },
      p_reason: why || null,
    },
    () => "Checks saved.",
    { invalid_input: "Check the numbers and try again." },
  );
}

/** Opens marking: the verified scripts that may be handed out are made ready to mark. */
export async function openMarkingAction(examId: string): Promise<MarkingActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  return callMarking(examId, "marking_open", {}, (a) => (a.already === true ? "Marking was already open." : `Marking is open. ${readyLine(a.ready)}`));
}

/** Closes marking, with a reason. Nothing is ended or deleted; nothing more is handed out. */
export async function closeMarkingAction(examId: string, reason: string): Promise<MarkingActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  return callMarking(examId, "marking_close", { p_reason: reason.trim() }, (a) =>
    a.already === true ? "Marking was already closed." : "Marking is closed. Nothing more is handed out to markers.",
  );
}

/** Reopens marking, with a reason. */
export async function reopenMarkingAction(examId: string, reason: string): Promise<MarkingActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return { ok: false, message: GENERIC };
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  return callMarking(examId, "marking_reopen", { p_reason: reason.trim() }, (a) =>
    a.already === true ? "Marking was already open." : `Marking is open again. ${readyLine(a.ready)}`,
  );
}
