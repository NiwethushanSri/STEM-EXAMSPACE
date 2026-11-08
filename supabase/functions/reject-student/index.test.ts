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

async function rejectedCount(svc: ReturnType<typeof service>, actor: string, since: string): Promise<number> {
  const { count } = await svc.from("audit_log").select("id", { count: "exact", head: true })
    .eq("action", "registration_rejected").eq("actor_id", actor).gte("created_at", since);
  return count ?? 0;
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
    const errs: string[] = [];
    try { await deleteUsers(svc, users); } catch (e) { errs.push(String(e)); }
    try { await deleteUserIds(svc, ids); } catch (e) { errs.push(String(e)); }
    if (errs.length) throw new Error(errs.join("; "));
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

Deno.test("reject-student: tutor caller -> 403; no Authorization -> 401", async () => {
  await withScenario(async ({ svc, track }) => {
    const t = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const r = await call(t.token, { studentId: crypto.randomUUID() });
    assertEquals(r.status, 403);
    const res = await fetch(url(), {
      method: "POST",
      headers: { apikey: env("SUPABASE_ANON_KEY"), "Content-Type": "application/json" },
      body: JSON.stringify({ studentId: crypto.randomUUID() }),
    });
    await res.body?.cancel();
    assertEquals(res.status, 401);
  });
});

Deno.test("reject-student: pending non-student -> 409", async () => {
  await withScenario(async ({ svc, admin, track }) => {
    const t = track(await createTestUser(svc, { role: "tutor", status: "pending" }));
    const since = new Date(Date.now() - 2000).toISOString();
    const r = await call(admin.token, { studentId: t.id });
    assertEquals(r.status, 409);
    assert(!(await gone(svc, t.id)));
    assertEquals(await rejectedCount(svc, admin.id, since), 0);
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
    const since = new Date(Date.now() - 2000).toISOString();
    const r = await call(admin.token, { studentId: crypto.randomUUID() });
    assertEquals(r.status, 404);
    assertEquals(await rejectedCount(service(), admin.id, since), 0);
    assertEquals(r.json.error.code, "not_found");
  });
});

Deno.test("reject-student: active student -> 409, nothing deleted", async () => {
  await withScenario(async ({ svc, admin, track }) => {
    const s = track(await createTestUser(svc, { role: "student", status: "active" }));
    const since = new Date(Date.now() - 2000).toISOString();
    const r = await call(admin.token, { studentId: s.id });
    assertEquals(r.status, 409);
    assertEquals(r.json.error.code, "conflict");
    assert(!(await gone(svc, s.id)));
    assertEquals(await rejectedCount(svc, admin.id, since), 0);
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
    assertEquals(audit?.length, 1);
    assertEquals(audit![0].actor_id, admin.id);
    assertEquals(audit![0].target_type, null);
    assertEquals(audit![0].target_id, null);

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
    const since = new Date(Date.now() - 2000).toISOString();
    const [a, b] = await Promise.all([
      call(admin.token, { studentId: s.id }),
      call(admin.token, { studentId: s.id }),
    ]);
    const codes = [a.status, b.status].sort();
    assertEquals(codes.filter((c) => c === 200).length, 1);
    const other = codes.find((c) => c !== 200)!;
    assert(other === 404 || other === 409, `unexpected ${other}`);
    assert(await gone(svc, s.id));
    assertEquals(await rejectedCount(svc, admin.id, since), 1);
  });
});

const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);
const hasPhoto = async (svc: ReturnType<typeof service>, id: string) => {
  const { data, error } = await svc.storage.from("student-photos").list(id);
  assertEquals(error, null);
  return (data ?? []).some((o) => o.name === "photo.jpg");
};

Deno.test("reject-student: the pending student's photo is removed with the account", async () => {
  await withScenario(async ({ svc, admin, track }) => {
    const s = track(await createTestUser(svc, { role: "student", status: "pending" }));
    const up = await svc.storage.from("student-photos").upload(`${s.id}/photo.jpg`, JPEG, { contentType: "image/jpeg", upsert: true });
    assertEquals(up.error, null);
    assert(await hasPhoto(svc, s.id));
    const r = await call(admin.token, { studentId: s.id });
    assertEquals(r.status, 200);
    assert(await gone(svc, s.id));
    assert(!(await hasPhoto(svc, s.id)), "photo must be removed");
  });
});

Deno.test("reject-student: a refused rejection (409) leaves the photo alone", async () => {
  await withScenario(async ({ svc, admin, track }) => {
    const s = track(await createTestUser(svc, { role: "student", status: "active" }));
    try {
      const up = await svc.storage.from("student-photos").upload(`${s.id}/photo.jpg`, JPEG, { contentType: "image/jpeg", upsert: true });
      assertEquals(up.error, null);
      const r = await call(admin.token, { studentId: s.id });
      assertEquals(r.status, 409);
      assert(await hasPhoto(svc, s.id), "photo must survive a refused rejection");
    } finally {
      await svc.storage.from("student-photos").remove([`${s.id}/photo.jpg`]);
    }
  });
});
