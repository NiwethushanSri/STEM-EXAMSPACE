import { assert, assertEquals } from "jsr:@std/assert@1";
import { anon, createTestUser, deleteUserIds, deleteUsers, env, service, type TestUser } from "../_shared/test_helpers.ts";

const url = () => `${env("SUPABASE_URL")}/functions/v1/register-student`;
const svc = service();

async function clearLimits() {
  const { error } = await svc.from("login_attempts").delete().or("key.like.reg:%,key.like.regx:%");
  if (error) throw new Error(`limit cleanup failed: ${error.code}`);
}

function body(email: string, over: Record<string, unknown> = {}) {
  return {
    firstName: "Nimal",
    lastName: "Perera",
    email,
    password: "Password-A-1234",
    dateOfBirth: "2012-03-04",
    school: "Royal College",
    parentName: "Kamal Perera",
    parentEmail: `parent-${crypto.randomUUID()}@example.test`,
    ...over,
  };
}

async function register(b: unknown): Promise<{ status: number; json: any }> {
  // No Authorization header at all: the function is public.
  const res = await fetch(url(), { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(b) });
  return { status: res.status, json: await res.json().catch(() => null) };
}

const uid = (email: string) => `t17-${crypto.randomUUID()}-${email}@example.test`;

async function userByEmail(email: string) {
  const { data } = await svc.from("profiles").select("id, status, role, first_name").eq("email", email).maybeSingle();
  return data as { id: string; status: string; role: string; first_name: string } | null;
}

async function signIn(email: string, password: string): Promise<boolean> {
  const { data, error } = await anon().auth.signInWithPassword({ email, password });
  return !error && !!data.session;
}

async function withCleanup(fn: (track: (email: string) => string) => Promise<void>) {
  const emails: string[] = [];
  await clearLimits();
  try {
    await fn((e) => (emails.push(e), e));
  } finally {
    const ids: string[] = [];
    for (const e of emails) {
      const p = await userByEmail(e);
      if (p) ids.push(p.id);
    }
    await clearLimits();
    await deleteUserIds(svc, ids);
  }
}

Deno.test("register-student: squatter's password and parent email do not survive the real owner registering", async () => {
  await withCleanup(async (track) => {
    const victim = track(uid("victim"));
    const attackerParent = `attacker-parent-${crypto.randomUUID()}@example.test`;
    const victimParent = `victim-parent-${crypto.randomUUID()}@example.test`;

    const a = await register(body(victim, { password: "Attacker-Pass-A1", parentEmail: attackerParent }));
    assertEquals(a.status, 200);
    assertEquals(a.json, { ok: true });
    const first = await userByEmail(victim);
    assert(first && first.status === "unconfirmed");

    const v = await register(body(victim, { password: "Victim-Pass-B2", parentEmail: victimParent }));
    assertEquals(v.status, 200);
    assertEquals(v.json, { ok: true });
    const second = await userByEmail(victim);
    assert(second && second.id !== first.id, "the pre-registration is replaced by a new account");
    assertEquals(second.status, "unconfirmed");

    // The victim follows the confirmation link (same token the email carries).
    const { data: link, error: lErr } = await svc.auth.admin.generateLink({ type: "signup", email: victim, password: "Victim-Pass-B2" });
    assert(!lErr && link.properties?.hashed_token);
    const verifier = anon();
    const { error: vErr } = await verifier.auth.verifyOtp({ token_hash: link.properties.hashed_token, type: "signup" });
    assertEquals(vErr, null);

    assertEquals(await signIn(victim, "Attacker-Pass-A1"), false, "the squatter's password must fail");
    assertEquals(await signIn(victim, "Victim-Pass-B2"), true);
    const confirmed = await userByEmail(victim);
    assertEquals(confirmed?.status, "pending");
    const { data: det } = await svc.from("student_details").select("signup_parent_email").eq("profile_id", second.id).single();
    assertEquals(det?.signup_parent_email, victimParent);
    assert(det?.signup_parent_email !== attackerParent);
  });
});

Deno.test("register-student: an already confirmed address gets the neutral answer and nothing changes", async () => {
  await withCleanup(async (track) => {
    const email = track(uid("confirmed"));
    const { data, error } = await svc.auth.admin.createUser({
      email, password: "Original-Pass-1", email_confirm: true, user_metadata: { first_name: "Orig", last_name: "Inal" },
    });
    assert(!error && data.user);
    const before = await userByEmail(email);

    const r = await register(body(email, { password: "Intruder-Pass-9", firstName: "Intruder" }));
    assertEquals(r.status, 200);
    assertEquals(r.json, { ok: true });

    const after = await userByEmail(email);
    assertEquals(after?.id, before?.id);
    assertEquals(after?.first_name, "Orig");
    assertEquals(await signIn(email, "Original-Pass-1"), true);
    assertEquals(await signIn(email, "Intruder-Pass-9"), false);
  });
});

Deno.test("register-student: staff (confirmed or not) are never touched", async () => {
  await withCleanup(async (track) => {
    const staff: TestUser = await createTestUser(svc, { role: "tutor", status: "active" });
    try {
      track(staff.email);
      const r = await register(body(staff.email, { password: "Intruder-Pass-9" }));
      assertEquals(r.status, 200);
      assertEquals(r.json, { ok: true });
      const p = await userByEmail(staff.email);
      assertEquals(p?.id, staff.id);
      assertEquals(p?.role, "tutor");
      assertEquals(await signIn(staff.email, "Intruder-Pass-9"), false);
    } finally {
      await deleteUsers(svc, [staff]);
    }

    // An unconfirmed shell that is not a plain student sign-up (here: a tutor) is protected too.
    const email = track(uid("unconfirmed-tutor"));
    const { data, error } = await svc.auth.admin.createUser({ email, password: "Shell-Pass-1234", email_confirm: false });
    assert(!error && data.user);
    const { error: uErr } = await svc.from("profiles").update({ role: "tutor", status: "unconfirmed" }).eq("id", data.user.id);
    assertEquals(uErr, null);
    const r2 = await register(body(email));
    assertEquals(r2.status, 200);
    assertEquals(r2.json, { ok: true });
    const p2 = await userByEmail(email);
    assertEquals(p2?.id, data.user.id);
    assertEquals(p2?.role, "tutor");
  });
});

Deno.test("register-student: response is identical for new, replaced and existing addresses", async () => {
  await withCleanup(async (track) => {
    const email = track(uid("shape"));
    const fresh = await register(body(email));
    const replaced = await register(body(email));
    const staff = await createTestUser(svc, { role: "admin", status: "active" });
    try {
      const existing = await register(body(staff.email));
      assertEquals(fresh.status, 200);
      assertEquals(JSON.stringify(replaced), JSON.stringify(fresh));
      assertEquals(JSON.stringify(existing), JSON.stringify(fresh));
    } finally {
      await deleteUsers(svc, [staff]);
    }
  });
});

Deno.test("register-student: validation errors are 400 and create nothing", async () => {
  await withCleanup(async (track) => {
    const email = track(uid("invalid"));
    const cases: Record<string, unknown> = {
      "short password": body(email, { password: "short" }),
      "long password": body(email, { password: "x".repeat(201) }),
      "bad email": body("not-an-email"),
      "bad parent email": body(email, { parentEmail: "nope" }),
      "too young": body(email, { dateOfBirth: new Date(Date.now() - 5 * 365.25 * 864e5).toISOString().slice(0, 10) }),
      "too old": body(email, { dateOfBirth: "1990-01-01" }),
      "impossible date": body(email, { dateOfBirth: "2012-02-31" }),
      "empty name": body(email, { firstName: "   " }),
      "long school": body(email, { school: "s".repeat(121) }),
      "missing field": { email, password: "Password-A-1234" },
      "array body": [],
    };
    for (const [name, b] of Object.entries(cases)) {
      const r = await register(b);
      assertEquals(r.status, 400, name);
      assertEquals(r.json.error.code, "invalid_input", name);
    }
    assertEquals(await userByEmail(email), null);
  });
});

Deno.test("register-student: rate limited per IP (429 on the 6th attempt)", async () => {
  await withCleanup(async (track) => {
    const email = track(uid("ratelimit"));
    // A confirmed address is the cheapest valid attempt (no email, no account).
    const { data, error } = await svc.auth.admin.createUser({ email, password: "Original-Pass-1", email_confirm: true });
    assert(!error && data.user);
    for (let i = 0; i < 5; i++) assertEquals((await register(body(email))).status, 200);
    const limited = await register(body(email));
    assertEquals(limited.status, 429);
    assertEquals(limited.json.error.code, "rate_limited");
  });
});
