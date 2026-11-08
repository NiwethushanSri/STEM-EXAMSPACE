import { createBrowserClient } from "@supabase/ssr";
import type { Database, StemClient } from "@stem/shared";

/** Browser Supabase client (anon key only, session kept in cookies so server components can read it). */
export function createClient(): StemClient {
  return createBrowserClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  ) as unknown as StemClient;
}
