import { assert, assertEquals } from "jsr:@std/assert@1";
import { decodeBase64 } from "jsr:@std/encoding@1/base64";
import { createTestUser, deleteUsers, env, service, type TestUser } from "../_shared/test_helpers.ts";

const BUCKET = "student-photos";
const JPEG = decodeBase64(
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=",
);
type Svc = ReturnType<typeof service>;

async function call(token: string | null): Promise<{ status: number; json: any }> {
  const headers: Record<string, string> = { apikey: env("SUPABASE_ANON_KEY"), "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`${env("SUPABASE_URL")}/functions/v1/delete-my-account`, { method: "POST", headers });
  return { status: res.status, json: await res.json().catch(() => null) };
}

const gone = async (svc: Svc, id: string) => {
  const { data } = await svc.from("profiles").select("id").eq("id", id);
  const { data: au } = await svc.auth.admin.getUserById(id);
  return (data ?? []).length === 0 && !au?.user;
};
const selfDeletes = async (svc: Svc) =>
  (await svc.from("audit_log").select("*", { count: "exact", head: true })
    .eq("action", "account_self_deleted").is("target_id", null).is("actor_id", null)).count ?? 0;

async function scenario(fn: (svc: Svc, track: (u: TestUser) => TestUser) => Promise<void>) {
  const svc = service();
  const users: TestUser[] = [];
  const photos: string[] = [];
  try {
    await fn(svc, (u) => (users.push(u), photos.push(`${u.id}/photo.jpg`), u));
  } finally {
    await svc.storage.from(BUCKET).remove(photos);
    await deleteUsers(svc, users);
  }
}

Deno.test("delete-my-account: pending student deletes self, photo and account gone, audit has no target", async () => {
  await scenario(async (svc, track) => {
    const s = track(await createTestUser(svc, { role: "student", status: "pending" }));
    const path = `${s.id}/photo.jpg`;
    const up = await svc.storage.from(BUCKET).upload(path, JPEG, { contentType: "image/jpeg", upsert: true });
    assertEquals(up.error, null);
    const before = await selfDeletes(svc);

    const r = await call(s.token);
    assertEquals(r.status, 200);
    assertEquals(r.json, { deleted: true });
    assert(await gone(svc, s.id));
    const { data: list } = await svc.storage.from(BUCKET).list(s.id);
    assertEquals((list ?? []).length, 0, "photo object removed");
    assertEquals(await selfDeletes(svc), before + 1);
  });
});

Deno.test("delete-my-account: suspended and unconfirmed students may delete themselves too", async () => {
  await scenario(async (svc, track) => {
    const a = track(await createTestUser(svc, { role: "student", status: "suspended" }));
    const b = track(await createTestUser(svc, { role: "student", status: "unconfirmed" }));
    assertEquals((await call(a.token)).status, 200);
    assertEquals((await call(b.token)).status, 200);
    assert(await gone(svc, a.id));
    assert(await gone(svc, b.id));
  });
});

Deno.test("delete-my-account: parent deletes self, the child and its photo are unaffected", async () => {
  await scenario(async (svc, track) => {
    const parent = track(await createTestUser(svc, { role: "parent", status: "active" }));
    const child = track(await createTestUser(svc, { role: "student", status: "active" }));
    const cp = `${child.id}/photo.jpg`;
    assertEquals((await svc.storage.from(BUCKET).upload(cp, JPEG, { contentType: "image/jpeg", upsert: true })).error, null);
    const { error } = await svc.from("parent_children").insert({ parent_id: parent.id, student_id: child.id });
    assertEquals(error, null);

    assertEquals((await call(parent.token)).status, 200);
    assert(await gone(svc, parent.id));
    assert(!(await gone(svc, child.id)), "child still exists");
    const { count } = await svc.from("parent_children").select("*", { count: "exact", head: true }).eq("student_id", child.id);
    assertEquals(count, 0);
    const { data: list } = await svc.storage.from(BUCKET).list(child.id);
    assertEquals((list ?? []).length, 1, "child's photo untouched");
  });
});

Deno.test("delete-my-account: staff -> 403 and keep their account; no token -> 401", async () => {
  await scenario(async (svc, track) => {
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const before = await selfDeletes(svc);
    assertEquals((await call(tutor.token)).status, 403);
    assertEquals((await call(admin.token)).status, 403);
    assert(!(await gone(svc, tutor.id)));
    assert(!(await gone(svc, admin.id)));
    assertEquals(await selfDeletes(svc), before);
    assertEquals((await call(null)).status, 401);
  });
});
