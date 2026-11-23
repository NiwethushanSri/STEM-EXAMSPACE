"use server";

import { revalidatePath } from "next/cache";
import { acceptReasonProblem, skipNoticesMessage } from "@/lib/home-drafts";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

export type SkipNoticesResult = { ok: boolean; message: string };

const GENERIC = "Something went wrong. Please try again.";

/** Stops the family emails still waiting (receipts, needs attention, rejected) from being sent, with the reason; the
 * database checks admin or owner again and keeps the reason in the audit log. Staff alerts are not touched. */
export async function skipFamilyNoticesAction(reason: string): Promise<SkipNoticesResult> {
  await requireStaff(["admin", "owner"]);
  const problem = acceptReasonProblem(reason);
  if (problem) return { ok: false, message: problem };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("script_family_notices_skip", { p_reason: reason.trim() });
  revalidatePath("/admin");
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, message: GENERIC };
  return skipNoticesMessage(data as Record<string, unknown>);
}
