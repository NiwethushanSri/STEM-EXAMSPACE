import type { SupabaseClient } from "@supabase/supabase-js";
import { HttpError } from "./errors.ts";

/**
 * Removes a user's photo before their account goes, so a child's photo is never orphaned (the key is the
 * user id, which can no longer be traced afterwards). "Not found" is fine; any other error stops the caller.
 */
export async function removePhoto(svc: SupabaseClient, userId: string): Promise<void> {
  const { error } = await svc.storage.from("student-photos").remove([`${userId}/photo.jpg`]);
  if (error && !/not.?found/i.test(error.message)) {
    console.error("photo removal failed:", error.message);
    throw new HttpError("internal", 500, "Something went wrong. Please try again.");
  }
}
