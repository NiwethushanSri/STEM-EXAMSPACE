import { requireCaller, serviceClient } from "../_shared/auth.ts";
import { removePhoto } from "../_shared/photos.ts";
import { HttpError, handle, jsonResponse } from "../_shared/errors.ts";

Deno.serve(handle(async (req) => {
  if (req.method !== "POST") throw new HttpError("invalid_input", 405, "Use POST.");
  // Students and parents only, in any status (an unconfirmed or suspended account may leave too).
  const caller = await requireCaller(req, ["student", "parent"], { anyStatus: true });
  const svc = serviceClient();

  // Photo first, so a child's photo is never orphaned (the key is the user id, gone with the account).
  await removePhoto(svc, caller.id);

  const { data, error } = await svc.rpc("delete_own_account_tx", { p_user: caller.id });
  if (error) throw new Error(`delete_own_account_tx failed: ${error.code ?? "unknown"}`);
  if (data === "forbidden") throw new HttpError("forbidden", 403, "You do not have permission to do this.");
  if (data !== "deleted") throw new Error("unexpected delete_own_account_tx result");
  return jsonResponse({ deleted: true });
}));
