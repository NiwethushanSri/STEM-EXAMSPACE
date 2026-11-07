import { createTestUser, deleteUserIds, deleteUsers, env, service, type TestUser } from "../_shared/test_helpers.ts";

// Shared setup for the parent-child test files (not itself a test file).
import { anon } from "../_shared/test_helpers.ts";
export { anon, createTestUser, deleteUserIds, deleteUsers, env, service };
export type { TestUser };
export type Svc = ReturnType<typeof service>;

export async function post(fn: string, token: string, body: unknown): Promise<{ status: number; json: any }> {
  const res = await fetch(`${env("SUPABASE_URL")}/functions/v1/${fn}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      apikey: env("SUPABASE_ANON_KEY"),
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  return { status: res.status, json: await res.json().catch(() => null) };
}
export const pc = (token: string, body: unknown) => post("parent-child", token, body);

export const childBody = (email: string, over: Record<string, unknown> = {}) => ({
  firstName: "Nimal",
  lastName: "Silva",
  email,
  dateOfBirth: "2011-03-09",
  school: "Royal College",
  ...over,
});
export const newChildEmail = () => `t10c-child-${crypto.randomUUID()}@example.test`;

/**
 * Runs a scenario and always cleans up: tracked users, any profile created for tracked child emails,
 * and every rate-limit row the scenario's parents/indexes could have written.
 */
export async function withScenario(fn: (ctx: {
  svc: Svc;
  track: (u: TestUser) => TestUser;
  childEmail: () => string;
  trackKey: (key: string) => void;
}) => Promise<void>) {
  const svc = service();
  const users: TestUser[] = [];
  const emails: string[] = [];
  const keys: string[] = [];
  try {
    await fn({
      svc,
      track: (u) => (users.push(u), u),
      childEmail: () => {
        const e = newChildEmail();
        emails.push(e);
        return e;
      },
      trackKey: (k) => void keys.push(k),
    });
  } finally {
    const extra: string[] = [];
    let qErr = false;
    if (emails.length) {
      const { data, error } = await svc.from("profiles").select("id").in("email", emails);
      if (error) qErr = true;
      for (const r of data ?? []) extra.push((r as { id: string }).id);
    }
    const allKeys = [...keys, ...users.flatMap((u) => [`preg:${u.id}`, `pregx:${u.id}`, `plink:${u.id}`])];
    const { error: kErr } = await svc.from("login_attempts").delete().in("key", allKeys);
    // parent_link_requests / links cascade with the users.
    await deleteUsers(svc, users);
    await deleteUserIds(svc, extra);
    if (qErr || kErr) throw new Error("test cleanup query failed");
  }
}

export const profileOf = async (svc: Svc, id: string) =>
  (await svc.from("profiles").select("status, role, first_name, last_name, email").eq("id", id).maybeSingle()).data;
export const idByEmail = async (svc: Svc, email: string): Promise<string | null> =>
  (await svc.from("profiles").select("id").eq("email", email).maybeSingle()).data?.id ?? null;
export const userGone = async (svc: Svc, id: string) => {
  const { data } = await svc.from("profiles").select("id").eq("id", id);
  const { data: au } = await svc.auth.admin.getUserById(id);
  return (data ?? []).length === 0 && !au?.user;
};
export async function confirm(svc: Svc, id: string) {
  const { error } = await svc.auth.admin.updateUserById(id, { email_confirm: true });
  if (error) throw new Error(`confirm failed: ${error.message}`);
}
