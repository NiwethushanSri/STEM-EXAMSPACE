import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { HttpError } from "./errors.ts";

export type AppRole = "owner" | "admin" | "teacher" | "tutor" | "corrector" | "student" | "parent";

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

const clientOptions = { auth: { persistSession: false, autoRefreshToken: false } };

export function serviceClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), clientOptions);
}

/**
 * Verifies the caller's JWT, then reads role and status from `profiles`
 * (never from JWT claims or the request body). Non-active accounts are refused.
 */
export async function requireCaller(
  req: Request,
  allowed: AppRole[],
): Promise<{ id: string; role: AppRole }> {
  const header = req.headers.get("Authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header);
  if (!match) throw new HttpError("unauthenticated", 401, "Sign in to continue.");

  const anon = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), clientOptions);
  const { data, error } = await anon.auth.getUser(match[1].trim());
  if (error || !data.user) throw new HttpError("unauthenticated", 401, "Sign in to continue.");

  const { data: profile, error: pErr } = await serviceClient()
    .from("profiles")
    .select("role, status")
    .eq("id", data.user.id)
    .maybeSingle();
  if (pErr) throw new Error(`profile lookup failed: ${pErr.message}`);

  if (!profile || profile.status !== "active" || !allowed.includes(profile.role as AppRole)) {
    throw new HttpError("forbidden", 403, "You do not have permission to do this.");
  }
  return { id: data.user.id, role: profile.role as AppRole };
}
