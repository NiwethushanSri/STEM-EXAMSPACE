import "server-only";
import { cache } from "react";
import { cookies } from "next/headers";
import { connection } from "next/server";
import { createServerClient } from "@supabase/ssr";
import type { AccountStatus, AppRole, Database } from "@stem/shared";

/** Server Supabase client bound to the request cookies (anon key; RLS is the real guard). */
export async function createClient() {
  // Request-time only: auth calls read the clock and must never run during prerendering.
  await connection();
  const cookieStore = await cookies();
  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => cookieStore.getAll(),
        setAll(list) {
          try {
            list.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
          } catch {
            // Called from a Server Component: the proxy refreshes the session instead.
          }
        },
      },
    },
  );
}

export type SessionProfile = {
  id: string;
  role: AppRole;
  status: AccountStatus;
  firstName: string;
  lastName: string;
};

/**
 * The signed-in user's profile, or null. Verifies the token with the auth server (getUser) and then
 * reads the role/status from `profiles` (never from JWT claims). Server components call this to re-check
 * what the proxy only checks optimistically.
 */
export const getSessionProfile = cache(async (): Promise<SessionProfile | null> => {
  const supabase = await createClient();
  const { data: auth } = await supabase.auth.getUser();
  if (!auth.user) return null;
  const { data } = await supabase
    .from("profiles")
    .select("id, role, status, first_name, last_name")
    .eq("id", auth.user.id)
    .maybeSingle();
  if (!data) return null;
  return { id: data.id, role: data.role, status: data.status, firstName: data.first_name, lastName: data.last_name };
});
