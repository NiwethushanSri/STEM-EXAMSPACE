"use server";

import { revalidatePath } from "next/cache";
import { paymentMessageFor } from "@stem/shared";
import { reasonProblem } from "@/lib/exception-queue";
import { isMonth, monthLabel, parseRateMissing, parseStatements, penceToPounds, RATE_MAX, statementCsv, type RateMissingExam } from "@/lib/marker-pay";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

/** What these actions send back; they never throw for expected failures. A refused fix may carry the earlier month to
 * fix first ("2027-02") or the exams that have no rate. */
export type PayActionResult =
  | { ok: true; message: string }
  | { ok: false; message: string; reasonRequired?: boolean; month?: string; exams?: RateMissingExam[] };

/** The month's statements as a CSV file, or why not. */
export type CsvResult = { ok: true; filename: string; csv: string } | { ok: false; message: string };

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;

const GENERIC = paymentMessageFor("internal");

/** One pay function's answer (the database checks the admin and every rule again), or null when it cannot be read. */
async function call(fn: string, args: Record<string, unknown>): Promise<Record<string, unknown> | null> {
  const supabase = await createClient();
  const { data, error } = await (supabase.rpc as unknown as Rpc)(fn, args);
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return null;
  return data as Record<string, unknown>;
}

const codeOf = (a: Record<string, unknown>) => (typeof a.code === "string" ? a.code : null);
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
const isCount = (v: unknown): v is number => typeof v === "number" && Number.isSafeInteger(v) && v >= 0;

/** An exam's pay rates, whole pence from 0 to 100,000 each: one with no group for an exam marked as whole scripts, one
 * per question group otherwise. Once a piece of the exam is in a fixed statement a change needs a reason (3 to 300
 * characters), and it reaches only marking not fixed yet. */
export async function setRates(examId: string, rates: { groupId: string | null; pence: number }[], reason?: string): Promise<PayActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId) || !Array.isArray(rates) || rates.length === 0 || rates.length > 200) return { ok: false, message: GENERIC };
  for (const r of rates) {
    if (!r || typeof r !== "object" || (r.groupId !== null && !isUuid(r.groupId))) return { ok: false, message: GENERIC };
    if (!Number.isSafeInteger(r.pence) || r.pence < 0 || r.pence > RATE_MAX) return { ok: false, message: paymentMessageFor("invalid_input") };
  }
  const why = typeof reason === "string" ? reason.trim() : "";
  const problem = reasonProblem(why, false);
  if (problem) return { ok: false, message: problem, reasonRequired: true };
  const a = await call("marker_rates_set", {
    p_exam: examId,
    p_rates: rates.map((r) => ({ group_id: r.groupId, pence: r.pence })),
    p_reason: why || null,
  });
  revalidatePath(`/admin/exams/${examId}`);
  revalidatePath("/admin/marking/payments");
  if (!a) return { ok: false, message: GENERIC };
  if (a.ok === true) return { ok: true, message: a.changed === false ? "The pay rates are unchanged." : "Pay rates saved." };
  const code = codeOf(a);
  return code === "reason_required" ? { ok: false, message: paymentMessageFor(code), reasonRequired: true } : { ok: false, message: paymentMessageFor(code) };
}

/** Fixes the month's statements ("2027-03"), once it has ended in UK time and every exam in it has a rate. Fixed
 * statements never change; markers fixed already are left alone. */
export async function fixMonth(month: string): Promise<PayActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!isMonth(month)) return { ok: false, message: GENERIC };
  const a = await call("marker_statements_fix", { p_month: `${month}-01` });
  revalidatePath("/admin/marking/payments");
  if (!a) return { ok: false, message: GENERIC };
  if (a.ok === true) {
    const { statements, pieces, total_pence: total } = a;
    // Figures it cannot read are not guessed: no "£0.00" for an amount it does not know.
    if (!isCount(statements) || !isCount(pieces) || !isCount(total)) return { ok: true, message: "The statements are fixed." };
    return {
      ok: true,
      message:
        statements === 0
          ? `Nothing was left to fix for ${monthLabel(month)}.`
          : `${plural(statements, "statement", "statements")} fixed for ${monthLabel(month)}: ${plural(pieces, "script", "scripts")}, ${penceToPounds(total)}.`,
    };
  }
  const code = codeOf(a);
  if (code === "earlier_month") {
    const earlier = typeof a.month === "string" ? a.month.slice(0, 7) : "";
    return { ok: false, message: paymentMessageFor(code, earlier), ...(isMonth(earlier) ? { month: earlier } : {}) };
  }
  if (code === "rate_missing") return { ok: false, message: paymentMessageFor(code), exams: parseRateMissing(a.exams) };
  return { ok: false, message: paymentMessageFor(code) };
}

/** The month's statements ("2027-03") as a CSV, fixed or not. Every export is recorded (Ruling R26): the CSV is made
 * first, then the export is recorded, and the CSV is given only when that succeeds. So no CSV leaves without its audit
 * row, and no row is written for an export that delivered nothing. */
export async function exportCsv(month: string): Promise<CsvResult> {
  await requireStaff(["admin", "owner"]);
  if (!isMonth(month)) return { ok: false, message: GENERIC };
  const got = parseStatements(await call("marker_statements_get", { p_month: `${month}-01` }));
  if (!got) return { ok: false, message: GENERIC };
  if (!got.ok) return { ok: false, message: paymentMessageFor(got.code) };
  const csv = statementCsv(got.statements);
  const recorded = await call("marker_statement_exported", { p_month: `${month}-01` });
  if (!recorded) return { ok: false, message: GENERIC };
  if (recorded.ok !== true) return { ok: false, message: paymentMessageFor(codeOf(recorded)) };
  return { ok: true, filename: `marker-statements-${month}.csv`, csv };
}
