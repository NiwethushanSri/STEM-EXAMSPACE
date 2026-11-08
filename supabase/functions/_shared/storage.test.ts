import { assert, assertEquals } from "jsr:@std/assert@1";
import { decodeBase64 } from "jsr:@std/encoding@1/base64";
import { createTestUser, deleteUsers, service, type TestUser } from "./test_helpers.ts";

const BUCKET = "student-photos";
// Smallest valid 1x1 JPEG.
const JPEG = decodeBase64(
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=",
);

Deno.test("storage_api_delete_own_photo_only", async () => {
  const svc = service();
  const users: TestUser[] = [];
  const paths: string[] = [];
  try {
    const a = await createTestUser(svc, { role: "student", status: "profile_incomplete" });
    users.push(a);
    const b = await createTestUser(svc, { role: "student", status: "profile_incomplete" });
    users.push(b);
    const pa = `${a.id}/photo.jpg`;
    const pb = `${b.id}/photo.jpg`;
    paths.push(pa, pb);

    const jpeg = { contentType: "image/jpeg", upsert: true };
    const upA = await a.client.storage.from(BUCKET).upload(pa, JPEG, jpeg);
    assertEquals(upA.error, null);
    const upB = await b.client.storage.from(BUCKET).upload(pb, JPEG, jpeg);
    assertEquals(upB.error, null);

    const exists = async (uid: string) => {
      const { data, error } = await svc.storage.from(BUCKET).list(uid);
      assertEquals(error, null);
      return (data ?? []).some((o) => o.name === "photo.jpg");
    };

    // A tries to delete B's object: B's object must remain.
    await a.client.storage.from(BUCKET).remove([pb]);
    assert(await exists(b.id), "B's photo must survive A's delete attempt");

    // A deletes own.
    const rm = await a.client.storage.from(BUCKET).remove([pa]);
    assertEquals(rm.error, null);
    assert(!(await exists(a.id)), "A's photo should be gone");

    // Non-JPEG rejected.
    const txt = await a.client.storage.from(BUCKET).upload(
      pa,
      new Blob(["hello"], { type: "text/plain" }),
      { contentType: "text/plain" },
    );
    assert(txt.error, "text/plain upload must be rejected");
    assertEquals((txt.error as { statusCode?: string }).statusCode, "415");
    assertEquals(txt.error.message, "mime type text/plain is not supported");
    assert(!(await exists(a.id)));

    // > 5 MB rejected.
    const big = new Uint8Array(5 * 1024 * 1024 + 1);
    big.set(JPEG);
    const bigUp = await a.client.storage.from(BUCKET).upload(pa, big, { contentType: "image/jpeg" });
    assert(bigUp.error, ">5MB upload must be rejected");
    assertEquals((bigUp.error as { statusCode?: string }).statusCode, "413");
    assertEquals(bigUp.error.message, "The object exceeded the maximum allowed size");
    assert(!(await exists(a.id)));
  } finally {
    try {
      if (paths.length) await svc.storage.from(BUCKET).remove(paths);
    } finally {
      await deleteUsers(svc, users);
    }
  }
});

Deno.test("storage_api_writes_need_a_learner_who_is_profile_incomplete_or_active", async () => {
  const svc = service();
  const users: TestUser[] = [];
  const paths: string[] = [];
  try {
    const pending = await createTestUser(svc, { role: "student", status: "pending" });
    users.push(pending);
    const parent = await createTestUser(svc, { role: "parent", status: "active" });
    users.push(parent);
    const active = await createTestUser(svc, { role: "student", status: "active" });
    users.push(active);
    const jpeg = { contentType: "image/jpeg", upsert: true };
    for (const u of [pending, parent]) {
      const p = `${u.id}/photo.jpg`;
      paths.push(p);
      const r = await u.client.storage.from(BUCKET).upload(p, JPEG, jpeg);
      assert(r.error, "write must be refused");
    }
    const ok = `${active.id}/photo.jpg`;
    paths.push(ok);
    assertEquals((await active.client.storage.from(BUCKET).upload(ok, JPEG, jpeg)).error, null);
    // After suspension the same learner cannot overwrite it.
    await svc.from("profiles").update({ status: "suspended" }).eq("id", active.id);
    const again = await active.client.storage.from(BUCKET).upload(ok, JPEG, jpeg);
    assert(again.error, "suspended learner must not overwrite");
  } finally {
    try {
      if (paths.length) await svc.storage.from(BUCKET).remove(paths);
    } finally {
      await deleteUsers(svc, users);
    }
  }
});
