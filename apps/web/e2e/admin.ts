// Test-only helper. Runs in the Playwright (Node) process, never in the app: it reads the service-role
// key from the git-ignored repo-root .env.dev.local to create users and links without any real email.
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

export const BASE = "http://localhost:3005";
export const CALLBACK = `${BASE}/auth/callback`;

function loadEnv(): Record<string, string> {
  const file = resolve(__dirname, "../../../.env.dev.local");
  const out: Record<string, string> = {};
  for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
  return out;
}

const env = loadEnv();
export const SUPABASE_URL = env.SUPABASE_URL;
export const ANON_KEY = env.SUPABASE_ANON_KEY;

let svcClient: SupabaseClient | null = null;
export function svc(): SupabaseClient {
  svcClient ??= createClient(SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return svcClient;
}

/** Emails that tests may sign up through the UI. Needs a domain GoTrue accepts; override with TEST_INBOX_DOMAIN. */
const DOMAIN = process.env.TEST_INBOX_DOMAIN ?? env.TEST_INBOX_DOMAIN ?? "example.com";
export const HAS_INBOX_DOMAIN = Boolean(process.env.TEST_INBOX_DOMAIN ?? env.TEST_INBOX_DOMAIN);
export const testEmail = (tag: string) => `e2e-${tag}-${crypto.randomUUID().slice(0, 8)}@${DOMAIN}`;
export const testPassword = () => `Pw-${crypto.randomUUID()}`;

const created = new Set<string>();
const createdEmails = new Set<string>();

/** Owner guard: refuse to run (or to delete anything) if a real owner exists on the dev project. */
export async function assertNoOwner(): Promise<void> {
  const { count, error } = await svc().from("profiles").select("*", { count: "exact", head: true }).eq("role", "owner");
  if (error) throw new Error(`owner check failed: ${error.code ?? "unknown"}`);
  if ((count ?? 0) > 0) throw new Error("A real owner exists on the dev project; e2e tests refuse to run");
}

export type TestAccount = { id: string; email: string; password: string; indexNumber?: string };

export async function createAccount(opts: {
  status?: "pending" | "profile_incomplete" | "active" | "suspended";
  indexNumber?: string;
  firstName?: string;
}): Promise<TestAccount> {
  const email = testEmail("acct");
  const password = testPassword();
  const { data, error } = await svc().auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { first_name: opts.firstName ?? "Casey", last_name: "Tester", school: "E2E School" },
  });
  if (error || !data.user) throw new Error(`createUser failed: ${error?.message}`);
  const id = data.user.id;
  created.add(id);
  if (opts.status && opts.status !== "pending") {
    const { error: e } = await svc().from("profiles").update({ status: opts.status }).eq("id", id);
    if (e) throw new Error(`status update failed: ${e.message}`);
  }
  if (opts.indexNumber) {
    const { error: e } = await svc().from("student_details").update({ index_number: opts.indexNumber }).eq("profile_id", id);
    if (e) throw new Error(`index update failed: ${e.message}`);
  }
  return { id, email, password, indexNumber: opts.indexNumber };
}

/** An account exactly as a self sign-up leaves it before the email link is used (status unconfirmed). */
export async function createUnconfirmed(): Promise<TestAccount> {
  const email = testEmail("unconf");
  const password = testPassword();
  const { data, error } = await svc().auth.admin.createUser({
    email,
    password,
    email_confirm: false,
    user_metadata: { first_name: "Una", last_name: "Confirmed", school: "E2E School" },
  });
  if (error || !data.user) throw new Error(`createUser failed: ${error?.message}`);
  created.add(data.user.id);
  return { id: data.user.id, email, password };
}

/** Track an email that the UI registered, so cleanup deletes it. */
export function trackEmail(email: string): void {
  createdEmails.add(email.toLowerCase());
}

export async function profileByEmail(email: string) {
  const { data } = await svc().from("profiles").select("id, role, status").eq("email", email.toLowerCase()).maybeSingle();
  return data;
}

/** Deletes every user this process created (by id and by tracked email). Throws if anything failed. */
export async function cleanup(): Promise<void> {
  const failed: string[] = [];
  for (const email of createdEmails) {
    const p = await profileByEmail(email);
    if (p) created.add(p.id);
  }
  for (const id of created) {
    const { data: prof } = await svc().from("profiles").select("role").eq("id", id).maybeSingle();
    if (prof?.role === "owner") {
      failed.push(`${id} (owner, refusing)`);
      continue;
    }
    const { error } = await svc().auth.admin.deleteUser(id);
    if (error && !/not found/i.test(error.message)) failed.push(id);
  }
  created.clear();
  createdEmails.clear();
  if (failed.length) throw new Error(`e2e cleanup failed for: ${failed.join(", ")}`);
}

/** Confirmation (signup) or recovery link for an existing user, plus the token_hash form of it. */
export async function linkFor(
  type: "signup" | "recovery" | "magiclink",
  email: string,
  password?: string,
): Promise<{ actionLink: string; tokenHash: string; type: string }> {
  const { data, error } = await svc().auth.admin.generateLink(
    type === "signup"
      ? { type, email, password: password ?? testPassword(), options: { redirectTo: CALLBACK } }
      : { type, email, options: { redirectTo: CALLBACK } },
  );
  if (error || !data.properties) throw new Error(`generateLink failed: ${error?.message}`);
  return {
    actionLink: data.properties.action_link,
    tokenHash: data.properties.hashed_token,
    type: data.properties.verification_type,
  };
}

/** Where GoTrue sends the browser after verifying a link (not followed). */
export async function redirectTarget(actionLink: string): Promise<string | null> {
  const res = await fetch(actionLink, { redirect: "manual" });
  return res.headers.get("location");
}

export async function countTestUsers(): Promise<number> {
  const { count } = await svc().from("profiles").select("*", { count: "exact", head: true }).like("email", "e2e-%");
  return count ?? 0;
}

/** Dev-only: forget index-login attempts so repeated runs from one IP never hit the 5-per-15-minutes limit. */
export async function clearLoginAttempts(): Promise<void> {
  const { error } = await svc().from("login_attempts").delete().gte("attempted_at", "1970-01-01");
  if (error) throw new Error(`clearing login attempts failed: ${error.code ?? "unknown"}`);
}
