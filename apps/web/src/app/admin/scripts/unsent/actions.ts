"use server";

import { revalidatePath } from "next/cache";
import { acceptDraftMessage, acceptReasonProblem } from "@/lib/home-drafts";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

export type AcceptDraftResult = { ok: boolean; message: string };

const GENERIC = "Something went wrong. Please try again.";

/** Submits a family's uploaded but unsent answers for them, with the reason; the database checks every rule again
 * (admin or owner only) and keeps the reason in the audit log. */
export async function acceptDraftAction(submissionId: string, reason: string): Promise<AcceptDraftResult> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(submissionId)) return { ok: false, message: GENERIC };
  const problem = acceptReasonProblem(reason);
  if (problem) return { ok: false, message: problem };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("home_submission_accept_draft", { p_submission: submissionId, p_reason: reason.trim() });
  revalidatePath("/admin/scripts/unsent");
  revalidatePath("/admin");
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, message: GENERIC };
  return acceptDraftMessage(data as Record<string, unknown>);
}
