import { requireCaller, serviceClient } from "../_shared/auth.ts";
import { HttpError, handle, jsonResponse } from "../_shared/errors.ts";

const BUCKET = "student-photos";

Deno.serve(handle(async (req) => {
  if (req.method !== "POST") throw new HttpError("invalid_input", 405, "Use POST.");
  // Students and parents only, in any status (an unconfirmed or suspended account may leave too).
  const caller = await requireCaller(req, ["student", "parent"], { anyStatus: true });
  const svc = serviceClient();

  // Photo first: the object is keyed by the user id, which is gone once the account is deleted.
  const { error: rmErr } = await svc.storage.from(BUCKET).remove([`${caller.id}/photo.jpg`]);
  if (rmErr && !/not.?found/i.test(rmErr.message)) {
    console.error("photo removal failed:", rmErr.message);
    throw new HttpError("internal", 500, "Something went wrong. Please try again.");
  }

  const { data, error } = await svc.rpc("delete_own_account_tx", { p_user: caller.id });
  if (error) throw new Error(`delete_own_account_tx failed: ${error.code ?? "unknown"}`);
  if (data === "forbidden") throw new HttpError("forbidden", 403, "You do not have permission to do this.");
  if (data !== "deleted") throw new Error("unexpected delete_own_account_tx result");
  return jsonResponse({ deleted: true });
}));
