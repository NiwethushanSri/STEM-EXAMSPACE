import { assert, assertEquals } from "jsr:@std/assert@1";
import { withScenario, act, userGone, withPassword, status, anon, createTestUser, env } from "./_helpers.ts";

Deno.test("account-admin: suspend bans sign-in, reactivate restores it; suspended admin loses staff reads", async () => {
  await withScenario(async ({ svc, track }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const pw = await withPassword(svc, tutor);
    const { error: pre } = await anon().auth.signInWithPassword({ email: tutor.email, password: pw });
    assertEquals(pre, null);

    const r = await act(admin.token, "suspend", tutor.id);
    assertEquals(r.status, 200);
    assertEquals(await status(svc, tutor.id), "suspended");
    const { data: s1, error: e1 } = await anon().auth.signInWithPassword({ email: tutor.email, password: pw });
    assert(e1 && !s1.session, "banned user cannot sign in");
    const { count: aud } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "account_suspended").eq("target_id", tutor.id).eq("actor_id", admin.id);
    assertEquals(aud, 1);
    // Suspend is idempotent: a retry succeeds and writes no second audit row.
    assertEquals((await act(admin.token, "suspend", tutor.id)).status, 200);
    const { count: aud2 } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "account_suspended").eq("target_id", tutor.id);
    assertEquals(aud2, 1);

    const back = await act(admin.token, "reactivate", tutor.id);
    assertEquals(back.status, 200);
    assertEquals(await status(svc, tutor.id), "active");
    const { data: s2, error: e2 } = await anon().auth.signInWithPassword({ email: tutor.email, password: pw });
    assertEquals(e2, null);
    assert(s2.session);
    assertEquals((await act(admin.token, "reactivate", tutor.id)).status, 200);
    const { count: aud3 } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "account_reactivated").eq("target_id", tutor.id);
    assertEquals(aud3, 1);

    // A suspended admin's existing session no longer reads other users' profiles.
    const owner = track(await createTestUser(svc, { role: "owner", status: "active" }));
    const before = await admin.client.from("profiles").select("id").eq("id", tutor.id);
    assertEquals(before.data!.length, 1);
    assertEquals((await act(owner.token, "suspend", admin.id)).status, 200);
    const after = await admin.client.from("profiles").select("id").eq("id", tutor.id);
    assertEquals(after.data!.length, 0);
    // ...and the Edge Function refuses it (the ban invalidates the token: 401, or 403 from the status check).
    const denied = (await act(admin.token, "suspend", tutor.id)).status;
    assert(denied === 401 || denied === 403, `suspended admin refused (got ${denied})`);
  });
});

Deno.test("account-admin: reactivated students land on active / profile_incomplete / pending", async () => {
  await withScenario(async ({ svc, track }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const a = track(await createTestUser(svc, { role: "student", status: "active" }));
    const b = track(await createTestUser(svc, { role: "student", status: "active" }));
    const c = track(await createTestUser(svc, { role: "student", status: "pending" }));
    const { data: subj } = await svc.from("subjects").select("id").limit(1).single();
    await svc.from("student_subjects").insert({ student_id: a.id, subject_id: subj!.id });
    await svc.from("student_details").update({ index_number: `SE-2098-${Math.floor(1000 + Math.random() * 8999)}` }).eq("profile_id", a.id);
    await svc.from("student_details").update({ index_number: `SE-2097-${Math.floor(1000 + Math.random() * 8999)}` }).eq("profile_id", b.id);
    for (const u of [a, b, c]) assertEquals((await act(admin.token, "suspend", u.id)).status, 200);
    for (const u of [a, b, c]) assertEquals((await act(admin.token, "reactivate", u.id)).status, 200);
    assertEquals(await status(svc, a.id), "active");
    assertEquals(await status(svc, b.id), "profile_incomplete");
    assertEquals(await status(svc, c.id), "pending");
  });
});

Deno.test("account-admin: forbidden combinations and 404", async () => {
  await withScenario(async ({ svc, track }) => {
    const owner = track(await createTestUser(svc, { role: "owner", status: "active" }));
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const admin2 = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    for (const action of ["suspend", "reactivate", "remove_staff"]) {
      assertEquals((await act(admin.token, action, admin.id)).status, 403, `admin self ${action}`);
      assertEquals((await act(owner.token, action, owner.id)).status, 403, `owner self ${action}`);
      assertEquals((await act(admin.token, action, owner.id)).status, 403, `admin on owner ${action}`);
      assertEquals((await act(admin.token, action, admin2.id)).status, 403, `admin on admin ${action}`);
      const u = await act(admin.token, action, crypto.randomUUID());
      assertEquals(u.status, 404, `unknown ${action}`);
      assertEquals(u.json.error.code, "not_found");
    }
    // Owner on admin is allowed (suspend, reactivate); only admin-on-admin is refused.
    assertEquals((await act(owner.token, "suspend", admin2.id)).status, 200);
    assertEquals((await act(owner.token, "reactivate", admin2.id)).status, 200);
    // Non-admins never reach the actions.
    assertEquals((await act(tutor.token, "suspend", admin.id)).status, 403);
    assertEquals(await status(svc, admin2.id), "active");
    assertEquals(await status(svc, owner.id), "active");
  });
});

Deno.test("account-admin: suspend/reactivate retries repair a failed Auth ban change (staff only), no extra audit", async () => {
  await withScenario(async ({ svc, track }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const a = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const b = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const pa = await withPassword(svc, a);
    const pb = await withPassword(svc, b);

    // Suspended in the database but never banned (the ban call failed): a suspend retry bans.
    await svc.from("profiles").update({ status: "suspended" }).eq("id", a.id);
    assertEquals((await act(admin.token, "suspend", a.id)).status, 200);
    const { error: ea } = await anon().auth.signInWithPassword({ email: a.email, password: pa });
    assert(ea, "retry banned the suspended tutor");

    // Active but still banned (the unban failed): a reactivate retry unbans.
    await svc.auth.admin.updateUserById(b.id, { ban_duration: "876000h" });
    assertEquals((await act(admin.token, "reactivate", b.id)).status, 200);
    const { error: eb } = await anon().auth.signInWithPassword({ email: b.email, password: pb });
    assertEquals(eb, null);

    // The retries wrote no audit rows (the state changes were made behind the function's back).
    const { count } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .in("action", ["account_suspended", "account_reactivated"]).in("target_id", [a.id, b.id]);
    assertEquals(count, 0);
  });
});

Deno.test("account-admin: suspending a student is status-only (no Auth ban); suspended student is gated but can self-delete", async () => {
  await withScenario(async ({ svc, track }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const s = track(await createTestUser(svc, { role: "student", status: "active" }));
    const pw = await withPassword(svc, s);
    assertEquals((await act(admin.token, "suspend", s.id)).status, 200);
    assertEquals(await status(svc, s.id), "suspended");

    const { data: sess, error } = await anon().auth.signInWithPassword({ email: s.email, password: pw });
    assertEquals(error, null);
    // Gated: a suspended student is refused by the staff function.
    assertEquals((await act(sess.session!.access_token, "suspend", admin.id)).status, 403);

    // ...and can still delete their own account (any status).
    const res = await fetch(`${env("SUPABASE_URL")}/functions/v1/delete-my-account`, {
      method: "POST",
      headers: { Authorization: `Bearer ${sess.session!.access_token}`, apikey: env("SUPABASE_ANON_KEY") },
    });
    assertEquals(res.status, 200);
    assert(await userGone(svc, s.id));
  });
});
