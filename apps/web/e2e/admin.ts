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
const createdOwners = new Set<string>();

/** Same format as supabase/functions/_shared/links.ts buildAuthLink, as a path on the local site. */
export function authLinkPath(hashedToken: string, type: "recovery" | "signup" | "invite"): string {
  return `/auth/callback?token_hash=${encodeURIComponent(hashedToken)}&type=${type}`;
}
const createdEmails = new Set<string>();

/** Owner guard: refuse to run (or to delete anything) if a real owner exists on the dev project. */
export async function assertNoOwner(): Promise<void> {
  const { count, error } = await svc().from("profiles").select("*", { count: "exact", head: true }).eq("role", "owner");
  if (error) throw new Error(`owner check failed: ${error.code ?? "unknown"}`);
  if ((count ?? 0) > 0) throw new Error("A real owner exists on the dev project; e2e tests refuse to run");
}

export type TestAccount = { id: string; email: string; password: string; indexNumber?: string };

export async function createAccount(opts: {
  role?: "owner" | "admin" | "teacher" | "tutor" | "corrector" | "parent";
  status?: "pending" | "profile_incomplete" | "active" | "suspended";
  indexNumber?: string;
  firstName?: string;
  email?: string;
}): Promise<TestAccount> {
  if (opts.role === "owner") await assertNoOwner();
  const email = opts.email ?? testEmail("acct");
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
  if (opts.role === "owner") createdOwners.add(id);
  const patch: Record<string, string> = {};
  if (opts.role) patch.role = opts.role;
  if (opts.status && opts.status !== "pending") patch.status = opts.status;
  if (opts.role && !opts.status) patch.status = "active";
  if (Object.keys(patch).length) {
    const { error: e } = await svc().from("profiles").update(patch).eq("id", id);
    if (e) throw new Error(`profile update failed: ${e.message}`);
  }
  if (opts.role) await svc().from("student_details").delete().eq("profile_id", id);
  if (opts.indexNumber) {
    const { error: e } = await svc().from("student_details").update({ index_number: opts.indexNumber }).eq("profile_id", id);
    if (e) throw new Error(`index update failed: ${e.message}`);
  }
  return { id, email, password, indexNumber: opts.indexNumber };
}

/**
 * A student exactly as a confirmed self sign-up leaves it (status pending, parent snapshot filled in), so it
 * shows in the admin approval list. `requestedBy` marks it as registered by that parent.
 */
export async function createPendingStudent(opts: {
  parentEmail: string;
  parentName?: string;
  requestedBy?: string;
  firstName?: string;
  email?: string;
}): Promise<TestAccount> {
  const email = opts.email ?? testEmail("pend");
  const password = testPassword();
  const { data, error } = await svc().auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: {
      first_name: opts.firstName ?? "Pen",
      last_name: "Ding",
      school: "E2E School",
      date_of_birth: "2009-04-12",
      parent_name: opts.parentName ?? "Pat Ding",
      parent_email: opts.parentEmail,
    },
  });
  if (error || !data.user) throw new Error(`createUser failed: ${error?.message}`);
  created.add(data.user.id);
  if (opts.requestedBy) {
    const { error: e } = await svc().from("student_details").update({ requested_by_parent: opts.requestedBy }).eq("profile_id", data.user.id);
    if (e) throw new Error(`requested_by update failed: ${e.message}`);
  }
  return { id: data.user.id, email, password };
}

/** A pending parent_link_requests row (what the parent-child function creates), without the rate limit. */
export async function createLinkRequest(parentId: string, studentId: string): Promise<string> {
  const { data, error } = await svc().from("parent_link_requests").insert({ parent_id: parentId, student_id: studentId }).select("id").single();
  if (error || !data) throw new Error(`link request failed: ${error?.message}`);
  return data.id;
}

/** Can this user (signed in with email+password through the anon key, RLS applies) read the profile? */
export async function canRead(email: string, password: string, profileId: string): Promise<boolean> {
  const c = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error: se } = await c.auth.signInWithPassword({ email, password });
  if (se) throw new Error(`test sign-in failed: ${se.message}`);
  const { data, error } = await c.from("profiles").select("id").eq("id", profileId);
  await c.auth.signOut();
  if (error) throw new Error(`read failed: ${error.code ?? "unknown"}`);
  return (data ?? []).length === 1;
}

export async function parentLinked(parentId: string, studentId: string): Promise<boolean> {
  const { count } = await svc().from("parent_children").select("*", { count: "exact", head: true }).eq("parent_id", parentId).eq("student_id", studentId);
  return (count ?? 0) > 0;
}

export async function studentDetails(id: string) {
  const { data } = await svc().from("student_details").select("index_number").eq("profile_id", id).maybeSingle();
  return data;
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
    if (prof?.role === "owner" && !createdOwners.has(id)) {
      failed.push(`${id} (owner, refusing)`);
      continue;
    }
    const { error } = await svc().auth.admin.deleteUser(id);
    if (error && !/not found/i.test(error.message)) failed.push(id);
  }
  created.clear();
  createdOwners.clear();
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
  if (!SUPABASE_URL.includes("jmhjahwfskhlgagaqlrz")) throw new Error("refusing to touch a project other than stem-examspace-dev");
  const { error } = await svc().from("login_attempts").delete().gte("attempted_at", "1970-01-01");
  if (error) throw new Error(`clearing login attempts failed: ${error.code ?? "unknown"}`);
}

/** Signs in through the real /login form. */
export async function signInUI(page: import("@playwright/test").Page, email: string, password: string): Promise<void> {
  await page.goto("/login");
  await page.getByLabel("Email or index number").fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in" }).click();
}

/** Marks a pending student as approved without going through the function (so no parent is created). */
export async function approveDirectly(id: string, index: string): Promise<void> {
  const { error: e1 } = await svc().from("student_details").update({ index_number: index }).eq("profile_id", id);
  const { error: e2 } = await svc().from("profiles").update({ status: "profile_incomplete" }).eq("id", id);
  if (e1 || e2) throw new Error(`approveDirectly failed: ${e1?.message ?? e2?.message}`);
}

/** A parent invite row plus its never-claimed sign-up shell, as left by an interrupted approval. */
export async function createStuckInvite(email: string): Promise<void> {
  const { data: inv, error } = await svc().from("pending_invites").insert({ email, role: "parent" }).select("token").single();
  if (error || !inv) throw new Error(`invite insert failed: ${error?.message}`);
  const { data, error: e } = await svc().auth.admin.createUser({ email, email_confirm: true, app_metadata: { invite_token: inv.token } });
  if (e || !data.user) throw new Error(`shell create failed: ${e?.message}`);
  created.add(data.user.id);
}

export async function inviteCount(email: string): Promise<number> {
  const { count } = await svc().from("pending_invites").select("*", { count: "exact", head: true }).eq("email", email.toLowerCase());
  return count ?? 0;
}

export async function removeInvite(email: string): Promise<void> {
  await svc().from("pending_invites").delete().eq("email", email.toLowerCase());
}

/**
 * Compiles the staff routes once (dev server, cold start) before the first browser test, so the dev-only
 * instant-navigation validation render cannot race the first sign-in redirect.
 */
export async function warmUp(): Promise<void> {
  for (const path of ["/admin", "/admin/accounts", "/owner", "/owner/staff", "/owner/accounts"]) {
    await fetch(`${BASE}${path}`, { redirect: "manual" }).catch(() => undefined);
  }
}
