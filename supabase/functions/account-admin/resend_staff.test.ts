import { assert, assertEquals } from "jsr:@std/assert@1";
import { post, resend, pendingStudent, withScenario, markApproved, approvedIndex, status, createTestUser } from "./_helpers.ts";

Deno.test("account-admin: resend (a) for a tutor with no invite_sent_at -> 200, set; second time 409; audited", async () => {
  await withScenario(async ({ svc, track }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    await svc.from("profiles").update({ invite_sent_at: null }).eq("id", tutor.id);
    const r = await resend(admin.token, tutor.id);
    assertEquals(r.status, 200);
    assertEquals(r.json.emailSent, true);
    assert(!JSON.stringify(r.json).toLowerCase().includes("link"));
    const { data: p } = await svc.from("profiles").select("invite_sent_at").eq("id", tutor.id).single();
    assert(p!.invite_sent_at);
    const { count: aud } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "invite_resent").eq("target_id", tutor.id).eq("actor_id", admin.id);
    assertEquals(aud, 1);
    const again = await resend(admin.token, tutor.id);
    assertEquals(again.status, 409);
    assertEquals(again.json.error.code, "conflict");
  });
});

Deno.test("account-admin: admin cannot resend for admin or owner; owner can", async () => {
  await withScenario(async ({ svc, track }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const owner = track(await createTestUser(svc, { role: "owner", status: "active" }));
    const otherAdmin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    for (const target of [otherAdmin.id, owner.id]) {
      const r = await resend(admin.token, target);
      assertEquals(r.status, 403);
      assertEquals(r.json.error.code, "forbidden");
    }
    const { data: p } = await svc.from("profiles").select("invite_sent_at").eq("id", otherAdmin.id).single();
    assertEquals(p!.invite_sent_at, null);
    const ok = await resend(owner.token, otherAdmin.id);
    assertEquals(ok.status, 200);
    const { data: p2 } = await svc.from("profiles").select("invite_sent_at").eq("id", otherAdmin.id).single();
    assert(p2!.invite_sent_at);
  });
});

Deno.test("account-admin: caller and input checks", async () => {
  await withScenario(async ({ svc, track }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const student = track(await createTestUser(svc, { role: "student", status: "active" }));
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    assertEquals((await resend(student.token, tutor.id)).status, 403);
    assertEquals((await resend(tutor.token, tutor.id)).status, 403);
    assertEquals((await post("account-admin", admin.token, { action: "resend_invite", userId: "nope" })).status, 400);
    assertEquals((await post("account-admin", admin.token, { action: "explode", userId: tutor.id })).status, 400);
    assertEquals((await post("account-admin", admin.token, {})).status, 400);
    const missing = await resend(admin.token, crypto.randomUUID());
    assertEquals(missing.status, 404);
    assertEquals(missing.json.error.code, "not_found");
    // A student that is not approved (no index number) is a conflict.
    const unapproved = await resend(admin.token, student.id);
    assertEquals(unapproved.status, 409);
    assertEquals(unapproved.json.error.code, "conflict");
  });
});

Deno.test("account-admin: resend (a) on a parent target works; suspended target -> 409", async () => {
  await withScenario(async ({ svc, track }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const parent = track(await createTestUser(svc, { role: "parent", status: "active" }));
    const r = await resend(admin.token, parent.id);
    assertEquals(r.status, 200);
    assertEquals(r.json.emailSent, true);
    const { data: p } = await svc.from("profiles").select("invite_sent_at").eq("id", parent.id).single();
    assert(p!.invite_sent_at);
    const sus = track(await createTestUser(svc, { role: "tutor", status: "suspended" }));
    const r2 = await resend(admin.token, sus.id);
    assertEquals(r2.status, 409);
    assertEquals(r2.json.error.code, "conflict");
  });
});

Deno.test("account-admin: owner admin-invite racing resend (b) for the same email never yields a parent from the admin invite", async () => {
  await withScenario(async ({ svc, track, parentEmail }) => {
    const owner = track(await createTestUser(svc, { role: "owner", status: "active" }));
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const s = track(await pendingStudent(svc, parentEmail));
    await markApproved(svc, s.id, approvedIndex());
    const [inv, rs] = await Promise.all([
      post("invite-user", owner.token, { email: parentEmail, firstName: "Ada", lastName: "Admin", role: "admin" }),
      resend(admin.token, s.id),
    ]);
    assert(inv.status !== 500 && rs.status !== 500, `no 500s (got ${inv.status}, ${rs.status})`);
    const { data: ps } = await svc.from("profiles").select("role").eq("email", parentEmail);
    assert(ps!.length <= 1, "never two accounts for one email");
    if (inv.status === 200) {
      // The admin invite won: the account must be the admin, and the resend must not have created a parent.
      assertEquals(ps![0].role, "admin");
      assert(rs.status === 409, `resend lost the race (${rs.status})`);
    } else {
      // The parent invite won: the staff invite is refused and the account is a parent.
      assertEquals(inv.status, 409);
      assertEquals(ps![0].role, "parent");
    }
  });
});
