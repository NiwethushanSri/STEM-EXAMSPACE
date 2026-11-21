"use server";

import { revalidatePath } from "next/cache";
import { reasonProblem } from "@/lib/exception-queue";
import { repoDoneMessage, repoFailureMessage, repoRpc, type RepoInput } from "@/lib/script-repository";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

/** What these actions send back; they never throw for expected failures. */
export type RepoActionResult = { ok: true; message: string } | { ok: false; message: string };

const GENERIC = "Something went wrong. Please try again.";

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;

function valid(scriptId: string, input: RepoInput): boolean {
  if (!isUuid(scriptId)) return false;
  switch (input.action) {
    case "rotate":
      return isUuid(input.pageId) && [1, -1, 2].includes(input.turns);
    case "reprocess":
      return isUuid(input.uploadId);
    case "remove":
      return Number.isInteger(input.copyPage) && input.copyPage > 0;
    case "void":
      return true;
    default:
      return false;
  }
}

/** A page tool of the script repository (turn a page, process a file again, take a page out, void the script), each
 * with a reason that goes into the audit log. The database checks every rule again. */
export async function scriptRepositoryAction(scriptId: string, input: RepoInput): Promise<RepoActionResult> {
  await requireStaff(["admin", "owner"]);
  if (!input || typeof input !== "object" || !valid(scriptId, input)) return { ok: false, message: GENERIC };
  const problem = reasonProblem(typeof input.reason === "string" ? input.reason : "", true);
  if (problem) return { ok: false, message: problem };

  const { fn, args } = repoRpc(scriptId, input);
  const supabase = await createClient();
  const { data, error } = await (supabase.rpc as unknown as Rpc)(fn, args);
  revalidatePath(`/admin/scripts/${scriptId}`);
  revalidatePath("/admin/scripts");
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, message: GENERIC };
  const a = data as { ok?: unknown; code?: unknown; reason?: unknown };
  return a.ok === true ? { ok: true, message: repoDoneMessage(input) } : { ok: false, message: repoFailureMessage(a) };
}
