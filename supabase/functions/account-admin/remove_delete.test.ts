import { assert, assertEquals } from "jsr:@std/assert@1";
import { type TestUser, post, pendingStudent, withScenario, act, userGone, status, BUCKET, JPEG, createTestUser } from "./_helpers.ts";

Deno.test("account-admin: remove_staff - admin removes tutor, not admin; owner removes admin; students refused", async () => {
  await withScenario(async ({ svc, track }) => {
    const owner = track(await createTestUser(svc, { role: "owner", status: "active" }));
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const admin2 = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const student = track(await createTestUser(svc, { role: "student", status: "active" }));

    const r = await act(admin.token, "remove_staff", tutor.id);
    assertEquals(r.status, 200);
    assertEquals(r.json, { removed: true });
    assert(await userGone(svc, tutor.id));
    const { count } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "staff_removed").eq("target_id", tutor.id).eq("actor_id", admin.id).eq("target_type", "profile");
    assertEquals(count, 1);

    assertEquals((await act(admin.token, "remove_staff", admin2.id)).status, 403);
    assert(!(await userGone(svc, admin2.id)));
    const conflict = await act(admin.token, "remove_staff", student.id);
    assertEquals(conflict.status, 409);
    assertEquals(conflict.json.error.code, "conflict");
    assert(!(await userGone(svc, student.id)));

    assertEquals((await act(owner.token, "remove_staff", admin2.id)).status, 200);
    assert(await userGone(svc, admin2.id));
  });
});

Deno.test("account-admin: clear_stuck_invite removes a crafted shell + invite, never a genuine student", async () => {
  await withScenario(async ({ svc, track, parentEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const owner = track(await createTestUser(svc, { role: "owner", status: "active" }));
    const clear = (token: string, email: string) => post("account-admin", token, { action: "clear_stuck_invite", email });

    // Crafted token-bearing shell + parent invite.
    const { error: iErr } = await svc.from("pending_invites").insert({ email: parentEmail, role: "parent" });
    assertEquals(iErr, null);
    const { data: inv } = await svc.from("pending_invites").select("token").eq("email", parentEmail).single();
    const { data: made, error: cErr } = await svc.auth.admin.createUser({
      email: parentEmail, email_confirm: true, app_metadata: { invite_token: inv!.token },
    });
    assertEquals(cErr, null);
    const shellId = made.user!.id;
    track({ id: shellId } as TestUser); // cleanup even if an assertion below fails

    assertEquals((await clear(admin.token, "nobody-" + parentEmail)).status, 404);
    const r = await clear(admin.token, parentEmail.toUpperCase());
    assertEquals(r.status, 200);
    const { count: left } = await svc.from("pending_invites").select("*", { count: "exact", head: true }).eq("email", parentEmail);
    assertEquals(left, 0);
    assert(await userGone(svc, shellId));
    const { count: aud } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "invite_cleared").eq("actor_id", admin.id).is("target_id", null);
    assertEquals(aud, 1);

    // A genuine pending student with the invite's email (no token): the invite goes, the student stays.
    const real = track(await pendingStudent(svc, `p-${crypto.randomUUID()}@example.test`));
    try {
      await svc.from("pending_invites").insert({ email: real.email, role: "parent" });
      assertEquals((await clear(admin.token, real.email)).status, 200);
      assert(!(await userGone(svc, real.id)), "genuine student untouched");
    } finally {
      await svc.from("pending_invites").delete().eq("email", real.email);
    }

    // Staff invites: admin 403 (invite kept), owner 200.
    await svc.from("pending_invites").insert({ email: parentEmail, role: "tutor" });
    assertEquals((await clear(admin.token, parentEmail)).status, 403);
    const { count: kept } = await svc.from("pending_invites").select("*", { count: "exact", head: true }).eq("email", parentEmail);
    assertEquals(kept, 1);
    assertEquals((await clear(owner.token, parentEmail)).status, 200);
    const { count: gone } = await svc.from("pending_invites").select("*", { count: "exact", head: true }).eq("email", parentEmail);
    assertEquals(gone, 0);
  });
});

Deno.test("account-admin: delete_account removes a student with photo and no-target audit; staff 409; self 403", async () => {
  await withScenario(async ({ svc, track }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const student = track(await createTestUser(svc, { role: "student", status: "suspended" }));
    const path = `${student.id}/photo.jpg`;
    try {
      assertEquals((await svc.storage.from(BUCKET).upload(path, JPEG, { contentType: "image/jpeg", upsert: true })).error, null);
      const { count: before } = await svc.from("audit_log").select("*", { count: "exact", head: true })
        .eq("action", "account_deleted").eq("actor_id", admin.id).is("target_id", null);

      const r = await act(admin.token, "delete_account", student.id);
      assertEquals(r.status, 200);
      assertEquals(r.json, { deleted: true });
      assert(await userGone(svc, student.id));
      const { data: list } = await svc.storage.from(BUCKET).list(student.id);
      assertEquals((list ?? []).length, 0, "photo removed");
      const { count: after } = await svc.from("audit_log").select("*", { count: "exact", head: true })
        .eq("action", "account_deleted").eq("actor_id", admin.id).is("target_id", null);
      assertEquals(after, (before ?? 0) + 1);

      assertEquals((await act(admin.token, "delete_account", tutor.id)).status, 409);
      assert(!(await userGone(svc, tutor.id)));
      assertEquals((await act(admin.token, "delete_account", admin.id)).status, 403);
      assertEquals((await act(admin.token, "delete_account", crypto.randomUUID())).status, 404);
    } finally {
      await svc.storage.from(BUCKET).remove([path]);
    }
  });
});

Deno.test("account-admin: refused remove_staff/delete_account leave the target's photo; reactivate reports the real status", async () => {
  await withScenario(async ({ svc, track }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const admin2 = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const paths = [`${admin2.id}/photo.jpg`, `${tutor.id}/photo.jpg`];
    try {
      for (const p of paths) {
        assertEquals((await svc.storage.from(BUCKET).upload(p, JPEG, { contentType: "image/jpeg", upsert: true })).error, null);
      }
      assertEquals((await act(admin.token, "remove_staff", admin2.id)).status, 403);
      assertEquals((await act(admin.token, "delete_account", tutor.id)).status, 409);
      for (const [i, id] of [admin2.id, tutor.id].entries()) {
        const { data } = await svc.storage.from(BUCKET).list(id);
        assertEquals((data ?? []).length, 1, `photo ${i} still exists after refusal`);
      }
      // reactivating an already-active account reports its real status, not a hard-coded "active".
      await svc.from("profiles").update({ status: "pending" }).eq("id", tutor.id);
      const r = await act(admin.token, "reactivate", tutor.id);
      assertEquals(r.status, 200);
      assertEquals(r.json.status, "pending");
    } finally {
      await svc.storage.from(BUCKET).remove(paths);
    }
  });
});
