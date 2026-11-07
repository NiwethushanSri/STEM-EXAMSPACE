import { createClient, type SupabaseClient, type SupportedStorage } from "@supabase/supabase-js";
import type { Database } from "./database.types";

export type StemClient = SupabaseClient<Database>;

/**
 * Browser/mobile client. Takes only the URL and the public anon key; never pass a service-role key.
 *
 * NOTE: PostgREST embeds between `profiles` and `student_details` must name the foreign key
 * (`student_details!profile_id(...)`), because more than one relationship exists between them.
 */
export function createStemClient(
  url: string,
  anonKey: string,
  options?: { storage?: SupportedStorage; persistSession?: boolean },
): StemClient {
  return createClient<Database>(url, anonKey, {
    auth: {
      ...(options?.storage ? { storage: options.storage } : {}),
      ...(options?.persistSession !== undefined ? { persistSession: options.persistSession } : {}),
    },
  });
}
