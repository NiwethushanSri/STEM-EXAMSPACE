// Test-only helpers (not a *.test.ts file, so it is not collected as a test).
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

export const service = (): SupabaseClient =>
  createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });

export const anon = (): SupabaseClient =>
  createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });

export interface TestUser {
  id: string;
  email: string;
  client: SupabaseClient; // anon client signed in as this user
  token: string;
}

/** Fails fast when a persistent owner exists on dev (the one_owner index would break the suites). */
async function assertNoRealOwner(svc: SupabaseClient): Promise<void> {
  const { count, error } = await svc.from("profiles").select("*", { count: "exact", head: true }).eq("role", "owner");
  if (error) throw new Error(`owner check failed: ${error.code ?? "unknown"}`);
  if ((count ?? 0) > 0) throw new Error("A real owner exists on the dev project — tests need it removed");
}

export async function createTestUser(
  svc: SupabaseClient,
  opts: { role?: string; status?: string; metadata?: Record<string, unknown> } = {},
): Promise<TestUser> {
  if (opts.role === "owner") await assertNoRealOwner(svc);
  const email = `t6-${crypto.randomUUID()}@example.test`;
  const password = `Pw-${crypto.randomUUID()}`;
  const { data, error } = await svc.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: opts.metadata ?? {},
  });
  if (error || !data.user) throw new Error(`createUser failed: ${error?.message}`);
  const id = data.user.id;
  try {
    if (opts.role || opts.status) {
      const patch: Record<string, string> = {};
      if (opts.role) patch.role = opts.role;
      if (opts.status) patch.status = opts.status;
      const { error: e } = await svc.from("profiles").update(patch).eq("id", id);
      if (e) throw new Error(`profile update failed: ${e.message}`);
    }
    const client = anon();
    const { data: s, error: se } = await client.auth.signInWithPassword({ email, password });
    if (se || !s.session) throw new Error(`sign in failed: ${se?.message}`);
    return { id, email, client, token: s.session.access_token };
  } catch (err) {
    await deleteUserIds(svc, [id]);
    throw err;
  }
}

/** Attempts every deletion, then throws if any failed (ids only, no secrets). */
export async function deleteUserIds(svc: SupabaseClient, ids: string[]): Promise<void> {
  const failed: string[] = [];
  for (const id of ids) {
    try {
      const { error } = await svc.auth.admin.deleteUser(id);
      // Already-gone users are fine (tests may delete on purpose).
      if (error && !/not found/i.test(error.message)) failed.push(id);
    } catch {
      failed.push(id);
    }
  }
  if (failed.length) throw new Error(`test cleanup failed for user ids: ${failed.join(", ")}`);
}

export function deleteUsers(svc: SupabaseClient, users: TestUser[]): Promise<void> {
  return deleteUserIds(svc, users.map((u) => u.id));
}
