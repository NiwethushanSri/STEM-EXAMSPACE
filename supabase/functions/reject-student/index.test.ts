import { assert, assertEquals } from "jsr:@std/assert@1";
import { createTestUser, deleteUserIds, deleteUsers, env, service, type TestUser } from "../_shared/test_helpers.ts";

const url = () => `${env("SUPABASE_URL")}/functions/v1/reject-student`;

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
  admin: TestUser;
  track: (u: TestUser) => TestUser;
  trackId: (id: string) => void;
}) => Promise<void>) {
  const svc = service();
  const users: TestUser[] = [];
  const ids: string[] = [];
  try {
    const admin = await createTestUser(svc, { role: "admin", status: "active" });
    users.push(admin);
    await fn({ svc, admin, track: (u) => (users.push(u), u), trackId: (id) => void ids.push(id) });
  } finally {
    await deleteUsers(svc, users);
    await deleteUserIds(svc, ids);
  }
}

const gone = async (svc: ReturnType<typeof service>, id: string) => {
  const { data } = await svc.auth.admin.getUserById(id);
  return !data?.user;
};

Deno.test("reject-student: student caller -> 403", async () => {
  await withScenario(async ({ svc, track }) => {
    const s = track(await createTestUser(svc, { role: "student", status: "pending" }));
    const r = await call(s.token, { studentId: s.id });
    assertEquals(r.status, 403);
    assertEquals(r.json.error.code, "forbidden");
    assert(!(await gone(svc, s.id)));
  });
});

Deno.test("reject-student: bad body -> 400", async () => {
  await withScenario(async ({ admin }) => {
    for (const body of [{}, { studentId: "nope" }, { studentId: 5 }]) {
      const r = await call(admin.token, body);
      assertEquals(r.status, 400);
      assertEquals(r.json.error.code, "invalid_input");
    }
  });
});

Deno.test("reject-student: unknown uuid -> 404", async () => {
  await withScenario(async ({ admin }) => {
    const r = await call(admin.token, { studentId: crypto.randomUUID() });
    assertEquals(r.status, 404);
    assertEquals(r.json.error.code, "not_found");
  });
});

Deno.test("reject-student: active student -> 409, nothing deleted", async () => {
  await withScenario(async ({ svc, admin, track }) => {
    const s = track(await createTestUser(svc, { role: "student", status: "active" }));
    const r = await call(admin.token, { studentId: s.id });
    assertEquals(r.status, 409);
    assertEquals(r.json.error.code, "conflict");
    assert(!(await gone(svc, s.id)));
  });
});

Deno.test("reject-student: claim shell -> 409, nothing deleted", async () => {
  await withScenario(async ({ svc, admin, track }) => {
    const s = track(await createTestUser(svc, { role: "student", status: "pending" }));
    const { error } = await svc.auth.admin.updateUserById(s.id, { app_metadata: { invite_token: crypto.randomUUID() } });
    assert(!error);
    const r = await call(admin.token, { studentId: s.id });
    assertEquals(r.status, 409);
    assertEquals(r.json.error.code, "conflict");
    assert(!(await gone(svc, s.id)));
  });
});

Deno.test("reject-student: admin rejects pending student; audit has no target; email can re-register", async () => {
  await withScenario(async ({ svc, admin, track, trackId }) => {
    const s = track(await createTestUser(svc, { role: "student", status: "pending" }));
    await svc.from("student_details").update({ signup_parent_email: `p-${crypto.randomUUID()}@example.test` })
      .eq("profile_id", s.id);
    const since = new Date(Date.now() - 2000).toISOString();
    const r = await call(admin.token, { studentId: s.id });
    assertEquals(r.status, 200);
    assertEquals(typeof r.json.emailSent, "boolean");
    assert(await gone(svc, s.id));
    const { data: prof } = await svc.from("profiles").select("id").eq("id", s.id);
    assertEquals(prof?.length, 0);
    const { data: det } = await svc.from("student_details").select("profile_id").eq("profile_id", s.id);
    assertEquals(det?.length, 0);

    const { data: audit } = await svc.from("audit_log").select("actor_id, target_type, target_id")
      .eq("action", "registration_rejected").gte("created_at", since);
    assert(audit && audit.length >= 1);
    assert(audit.some((a) => a.actor_id === admin.id && a.target_type === null && a.target_id === null));

    const { data: again, error } = await svc.auth.admin.createUser({ email: s.email, email_confirm: true });
    assert(!error && again.user);
    trackId(again.user.id);
    const { data: p2 } = await svc.from("profiles").select("role").eq("id", again.user.id).single();
    assertEquals(p2?.role, "student");
  });
});

Deno.test("reject-student: concurrent double reject -> one 200, other 404/409", async () => {
  await withScenario(async ({ svc, admin, track }) => {
    const s = track(await createTestUser(svc, { role: "student", status: "pending" }));
    const [a, b] = await Promise.all([
      call(admin.token, { studentId: s.id }),
      call(admin.token, { studentId: s.id }),
    ]);
    const codes = [a.status, b.status].sort();
    assertEquals(codes.filter((c) => c === 200).length, 1);
    const other = codes.find((c) => c !== 200)!;
    assert(other === 404 || other === 409, `unexpected ${other}`);
    assert(await gone(svc, s.id));
  });
});
