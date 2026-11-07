import { assert, assertEquals } from "jsr:@std/assert@1";
import { createTestUser, deleteUserIds, deleteUsers, env, service, type TestUser } from "../_shared/test_helpers.ts";

const url = () => `${env("SUPABASE_URL")}/functions/v1/invite-user`;

async function call(token: string, body: unknown): Promise<{ status: number; json: any }> {
  const res = await fetch(url(), {
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

async function withScenario(fn: (ctx: {
  svc: ReturnType<typeof service>;
  track: (u: TestUser) => TestUser;
  newEmail: () => string;
}) => Promise<void>) {
  const svc = service();
  const users: TestUser[] = [];
  const emails: string[] = [];
  try {
    await fn({
      svc,
      track: (u) => (users.push(u), u),
      newEmail: () => {
        const e = `t10a-${crypto.randomUUID()}@example.test`;
        emails.push(e);
        return e;
      },
    });
  } finally {
    const extra: string[] = [];
    let qErr = "";
    for (const e of emails) {
      const { data, error } = await svc.from("profiles").select("id").eq("email", e);
      if (error) qErr += error.code ?? "?";
      extra.push(...(data ?? []).map((r: { id: string }) => r.id));
    }
    const { error: invErr } = emails.length
      ? await svc.from("pending_invites").delete().in("email", emails)
      : { error: null };
    await deleteUsers(svc, users);
    await deleteUserIds(svc, extra);
    if (qErr || invErr) throw new Error(`test cleanup query failed: ${qErr} ${invErr?.code ?? ""}`);
  }
}

Deno.test("invite-user: admin invites tutor -> 200, active tutor, invite_sent_at set, audited, no token leaked", async () => {
  await withScenario(async ({ svc, track, newEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const email = newEmail();
    const r = await call(admin.token, { email: ` ${email.toUpperCase()} `, firstName: "Tina", lastName: "Tutor", role: "tutor" });
    assertEquals(r.status, 200);
    assertEquals(r.json.invited, true);
    assertEquals(r.json.emailSent, true);
    assert(!JSON.stringify(r.json).toLowerCase().includes("token"));

    const { data: p } = await svc.from("profiles")
      .select("id, role, status, first_name, last_name, invite_sent_at").eq("email", email).single();
    assertEquals(p!.role, "tutor");
    assertEquals(p!.status, "active");
    assertEquals(p!.first_name, "Tina");
    assert(p!.invite_sent_at, "invite_sent_at must be set");
    const { count: inv } = await svc.from("pending_invites").select("*", { count: "exact", head: true }).eq("email", email);
    assertEquals(inv, 0);
    const { count: aud } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "staff_invited").eq("target_id", p!.id).eq("actor_id", admin.id);
    assertEquals(aud, 1);
    const { data: au } = await svc.auth.admin.getUserById(p!.id);
    assertEquals(au.user?.app_metadata?.invite_token ?? null, null);
  });
});

Deno.test("invite-user: admin cannot invite admin, owner, student or parent -> 403", async () => {
  await withScenario(async ({ svc, track, newEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    for (const role of ["admin", "owner", "student", "parent"]) {
      const email = newEmail();
      const r = await call(admin.token, { email, firstName: "A", lastName: "B", role });
      assertEquals(r.status, 403, role);
      assertEquals(r.json.error.code, "forbidden");
      const { data } = await svc.from("profiles").select("id").eq("email", email);
      assertEquals(data!.length, 0);
    }
  });
});

Deno.test("invite-user: owner invites admin -> 200, role admin; owner cannot invite owner", async () => {
  await withScenario(async ({ svc, track, newEmail }) => {
    const owner = track(await createTestUser(svc, { role: "owner", status: "active" }));
    const email = newEmail();
    const r = await call(owner.token, { email, firstName: "Ada", lastName: "Admin", role: "admin" });
    assertEquals(r.status, 200);
    const { data: p } = await svc.from("profiles").select("role, status").eq("email", email).single();
    assertEquals(p!.role, "admin");
    assertEquals(p!.status, "active");
    const r2 = await call(owner.token, { email: newEmail(), firstName: "O", lastName: "O", role: "owner" });
    assertEquals(r2.status, 403);
  });
});

Deno.test("invite-user: duplicate email -> 409 email_in_use (profile exists, any case)", async () => {
  await withScenario(async ({ svc, track, newEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const email = newEmail();
    const first = await call(admin.token, { email, firstName: "Tina", lastName: "Tutor", role: "tutor" });
    assertEquals(first.status, 200);
    const again = await call(admin.token, { email: email.toUpperCase(), firstName: "Tina", lastName: "Tutor", role: "teacher" });
    assertEquals(again.status, 409);
    assertEquals(again.json.error.code, "email_in_use");
    assertEquals(again.json.error.message, "An account with this email already exists.");
    // The existing account is untouched.
    const { data: p } = await svc.from("profiles").select("role").eq("email", email).single();
    assertEquals(p!.role, "tutor");
    // An existing test user's email too.
    const dup = await call(admin.token, { email: admin.email, firstName: "X", lastName: "Y", role: "tutor" });
    assertEquals(dup.status, 409);
  });
});

Deno.test("invite-user: student, parent and tutor callers -> 403; no auth -> 401", async () => {
  await withScenario(async ({ svc, track, newEmail }) => {
    for (const role of ["student", "parent", "tutor"]) {
      const u = track(await createTestUser(svc, { role, status: "active" }));
      const r = await call(u.token, { email: newEmail(), firstName: "A", lastName: "B", role: "tutor" });
      assertEquals(r.status, 403, role);
    }
    const res = await fetch(url(), {
      method: "POST",
      headers: { apikey: env("SUPABASE_ANON_KEY"), "Content-Type": "application/json" },
      body: "{}",
    });
    await res.body?.cancel();
    assertEquals(res.status, 401);
  });
});

Deno.test("invite-user: bad bodies -> 400 invalid_input", async () => {
  await withScenario(async ({ svc, track, newEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const ok = { email: newEmail(), firstName: "A", lastName: "B", role: "tutor" };
    const bad: unknown[] = [
      {},
      { ...ok, email: "not-an-email" },
      { ...ok, email: 5 },
      { ...ok, firstName: "" },
      { ...ok, firstName: "   " },
      { ...ok, lastName: "x".repeat(81) },
      { ...ok, role: "wizard" },
      { ...ok, role: 7 },
      [],
      "nope",
    ];
    for (const body of bad) {
      const r = await call(admin.token, body);
      assertEquals(r.status, 400, JSON.stringify(body));
      assertEquals(r.json.error.code, "invalid_input");
    }
    const { data } = await svc.from("profiles").select("id").eq("email", ok.email);
    assertEquals(data!.length, 0);
  });
});
