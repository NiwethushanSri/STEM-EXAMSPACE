"use server";

import { revalidatePath } from "next/cache";
import { allocationMessageFor } from "@stem/shared";
import { reasonProblem } from "@/lib/exception-queue";
import { secondSkipMessage } from "@/lib/marking-review";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

/** What these actions send back; they never throw for expected failures. */
export type AllocationActionResult = { ok: true; message: string } | { ok: false; message: string };

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;
type Answer = Record<string, unknown>;

const GENERIC = allocationMessageFor("internal", "admin");
const INVALID = allocationMessageFor("invalid_input", "admin");
const MAX = 200;

const count = (v: unknown) => (typeof v === "number" && Number.isSafeInteger(v) ? v : 0);
const scripts = (n: number) => `${n} ${n === 1 ? "script" : "scripts"}`;
/** 1 to 200 piece ids, each one. */
const goodUnits = (ids: unknown): ids is string[] => Array.isArray(ids) && ids.length >= 1 && ids.length <= MAX && ids.every(isUuid);

/** Calls one allocation function with the reason (3 to 300 characters); the database checks every rule again. */
async function call(fn: string, args: Record<string, unknown>, reason: string, done: (a: Answer) => string): Promise<AllocationActionResult> {
  const problem = reasonProblem(reason ?? "", true);
  if (problem) return { ok: false, message: problem };
  const supabase = await createClient();
  const { data, error } = await (supabase.rpc as unknown as Rpc)(fn, { ...args, p_reason: reason.trim() });
  revalidatePath("/admin/marking");
  revalidatePath("/marking");
  revalidatePath("/marking/review");
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, message: GENERIC };
  const a = data as Answer;
  if (a.ok === true) return { ok: true, message: done(a) };
  return { ok: false, message: allocationMessageFor(typeof a.code === "string" ? a.code : null, "admin") };
}

/** The scripts an assignment skipped, grouped by why: " 2 not assigned: A marker already has this script. ..." (in the
 * words of `say`: the allocation codes unless given). */
function skippedText(skipped: unknown, verb: string, say: (code: string) => string = (c) => allocationMessageFor(c, "admin")): string {
  const byCode = new Map<string, number>();
  for (const s of Array.isArray(skipped) ? skipped : []) {
    const c = s && typeof s === "object" && typeof (s as Answer).code === "string" ? ((s as Answer).code as string) : "internal";
    byCode.set(c, (byCode.get(c) ?? 0) + 1);
  }
  return [...byCode].map(([c, n]) => ` ${n} not ${verb}: ${say(c)}`).join("");
}

/** Gives the ticked pieces to a marker, with no time limit. */
export async function assignUnits(unitIds: string[], markerId: string, reason: string): Promise<AllocationActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!goodUnits(unitIds) || !isUuid(markerId)) return { ok: false, message: INVALID };
  return call("marking_assign", { p_units: unitIds, p_marker: markerId }, reason, (a) => `${scripts(count(a.assigned))} assigned.${skippedText(a.skipped, "assigned")}`);
}

/** Gives a marker the next `count` free pieces of the exam (of the group, when given), chosen as Next script would. */
export async function assignSome(examId: string, groupId: string | null, markerId: string, n: number, reason: string): Promise<AllocationActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId) || (groupId !== null && !isUuid(groupId)) || !isUuid(markerId) || !Number.isSafeInteger(n) || n < 1 || n > MAX) {
    return { ok: false, message: "Choose a marker and a number from 1 to 200." };
  }
  return call("marking_assign_some", { p_exam: examId, p_group: groupId, p_marker: markerId, p_count: n }, reason, (a) => {
    const done = count(a.assigned);
    return done === 0 ? "No script was free to assign." : `${scripts(done)} assigned.`;
  });
}

/** Takes the ticked pieces back: their holds end and their markings are set aside. Nothing is deleted. */
export async function takeBackUnits(unitIds: string[], reason: string): Promise<AllocationActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!goodUnits(unitIds)) return { ok: false, message: INVALID };
  return call("marking_take_back", { p_units: unitIds }, reason, (a) => `${scripts(count(a.taken_back))} taken back.`);
}

/** Takes the ticked pieces back and gives them to another marker, in one go. */
export async function reassignUnits(unitIds: string[], markerId: string, reason: string): Promise<AllocationActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!goodUnits(unitIds) || !isUuid(markerId)) return { ok: false, message: INVALID };
  return call("marking_reassign", { p_units: unitIds, p_marker: markerId }, reason, (a) => `${scripts(count(a.assigned))} reassigned.${skippedText(a.skipped, "reassigned")}`);
}

/** "Second-mark these": the ticked scripts whose first marking is submitted are second-marked too. */
export async function addSecond(unitIds: string[], reason: string): Promise<AllocationActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!goodUnits(unitIds)) return { ok: false, message: INVALID };
  return call("marking_second_add", { p_units: unitIds }, reason, (a) => {
    const n = count(a.added);
    return `${scripts(n)} will be second-marked.${skippedText(a.skipped, "added", secondSkipMessage)}`;
  });
}

/** "Release from second marking": the ticked scripts waiting for a second marker are checked on their first marks. */
export async function dropSecond(unitIds: string[], reason: string): Promise<AllocationActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!goodUnits(unitIds)) return { ok: false, message: INVALID };
  return call("marking_second_drop", { p_units: unitIds }, reason, (a) =>
    `${scripts(count(a.dropped))} released from second marking.${skippedText(a.skipped, "released", secondSkipMessage)}`,
  );
}

/** "Assign second marking to…": gives the ticked scripts' second pass to a marker, with no time limit. A marker who saw
 * a name on the script, or whom a review may have shown its first marking, is never given it (not_eligible). */
export async function assignSecond(unitIds: string[], markerId: string, reason: string): Promise<AllocationActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!goodUnits(unitIds) || !isUuid(markerId)) return { ok: false, message: INVALID };
  return call("marking_assign", { p_units: unitIds, p_marker: markerId, p_kind: "second" }, reason, (a) =>
    `${scripts(count(a.assigned))} assigned for second marking.${skippedText(a.skipped, "assigned")}`,
  );
}

/** "Take back second marking": the ticked scripts' second pass ends and its marking is set aside; the first marking is
 * left as it is. Nothing is deleted. */
export async function takeBackSecond(unitIds: string[], reason: string): Promise<AllocationActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!goodUnits(unitIds)) return { ok: false, message: INVALID };
  return call("marking_take_back", { p_units: unitIds, p_kind: "second" }, reason, (a) => `Second marking of ${scripts(count(a.taken_back))} taken back.`);
}
