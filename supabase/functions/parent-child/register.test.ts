import { assert, assertEquals } from "jsr:@std/assert@1";
import { anon, childBody, confirm, createTestUser, idByEmail, pc, post, profileOf, userGone, withScenario } from "./_helpers.ts";

Deno.test("parent-child register: parent registers child -> unconfirmed, confirm -> pending, approve links; reject removes", async () => {
  await withScenario(async ({ svc, track, childEmail }) => {
    const parent = track(await createTestUser(svc, { role: "parent", status: "active" }));
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const e1 = childEmail();
    const r = await pc(parent.token, { action: "register", child: childBody(e1) });
    assertEquals(r.status, 200);
    assertEquals(r.json.registered, true);
    assertEquals(r.json.emailSent, true, "confirmation link generated and sent");
    assert(!JSON.stringify(r.json).includes("http"), "response must not carry the confirmation link");

    const cid = await idByEmail(svc, e1);
    assert(cid, "child profile exists");
    const p = await profileOf(svc, cid!);
    assertEquals(p!.status, "unconfirmed");
    assertEquals(p!.role, "student");
    const { data: det } = await svc.from("student_details")
      .select("signup_parent_email, requested_by_parent, date_of_birth, school").eq("profile_id", cid!).single();
    assertEquals(det!.signup_parent_email, parent.email.toLowerCase());
    assertEquals(det!.requested_by_parent, parent.id);
    assertEquals(det!.date_of_birth, "2011-03-09");
    assertEquals(det!.school, "Royal College");
    const { count: aud } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "child_registered_by_parent").eq("actor_id", parent.id).eq("target_id", cid!).eq("target_type", "profile");
    assertEquals(aud, 1);

    // No password exists: nothing the parent could know signs the child in.
    const probe = anon();
    for (const pw of ["Password123!", "x".repeat(12)]) {
      const { data: si, error: siErr } = await probe.auth.signInWithPassword({ email: e1, password: pw });
      assert(siErr && !si.session, "child cannot sign in with a guessed password");
    }

    // The parent cannot see the child before approval.
    const { data: seen } = await parent.client.from("profiles").select("id").eq("id", cid!);
    assertEquals((seen ?? []).length, 0);

    await confirm(svc, cid!);
    assertEquals((await profileOf(svc, cid!))!.status, "pending");
    const { data: seen2 } = await parent.client.from("profiles").select("id").eq("id", cid!);
    assertEquals((seen2 ?? []).length, 0, "pending child still invisible to the parent");

    const ok = await post("approve-student", admin.token, { studentId: cid });
    assertEquals(ok.status, 200);
    const { data: links } = await svc.from("parent_children").select("student_id").eq("parent_id", parent.id);
    assertEquals((links ?? []).map((l: { student_id: string }) => l.student_id), [cid]);
    const { data: seen3 } = await parent.client.from("profiles").select("id").eq("id", cid!);
    assertEquals((seen3 ?? []).length, 1, "approved child visible to the parent");

    // Second child, rejected: gone, no link.
    const e2 = childEmail();
    assertEquals((await pc(parent.token, { action: "register", child: childBody(e2) })).status, 200);
    const cid2 = (await idByEmail(svc, e2))!;
    await confirm(svc, cid2);
    const rej = await post("reject-student", admin.token, { studentId: cid2 });
    assertEquals(rej.status, 200);
    assert(await userGone(svc, cid2));
    const { data: links2 } = await svc.from("parent_children").select("student_id").eq("parent_id", parent.id);
    assertEquals((links2 ?? []).length, 1);
  });
});

Deno.test("parent-child register: non-parent 403, duplicate email 409, bad input 400, unauthenticated 401", async () => {
  await withScenario(async ({ svc, track, childEmail }) => {
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const student = track(await createTestUser(svc, { role: "student", status: "active" }));
    const parent = track(await createTestUser(svc, { role: "parent", status: "active" }));
    const e = childEmail();
    for (const u of [tutor, student]) {
      const r = await pc(u.token, { action: "register", child: childBody(e) });
      assertEquals(r.status, 403);
    }
    assertEquals(await idByEmail(svc, e), null, "nothing created for non-parents");
    assertEquals((await pc("not-a-token", { action: "register", child: childBody(e) })).status, 401);

    const overrides: Record<string, unknown>[] = [
      { email: "nope" },
      { dateOfBirth: "2020-01-01" },
      { dateOfBirth: "1990-01-01" },
      { firstName: "" },
      { lastName: "x".repeat(81) },
      { school: "" },
      { dateOfBirth: "2999-01-01" },
      { dateOfBirth: "2011-02-30" },
      { dateOfBirth: "yesterday" },
    ];
    for (const over of overrides) {
      const r = await pc(parent.token, { action: "register", child: childBody(e, over) });
      assertEquals(r.status, 400, JSON.stringify(Object.keys(over)));
      assertEquals(r.json.error.code, "invalid_input");
    }
    assertEquals((await pc(parent.token, { action: "register" })).status, 400);
    assertEquals(await idByEmail(svc, e), null);
    assertEquals((await pc(parent.token, { action: "nope" })).status, 400);

    // A pending invite for the address also refuses (and is left alone).
    const invited = childEmail();
    const { error: iErr } = await svc.from("pending_invites").insert({ email: invited, role: "parent" });
    assertEquals(iErr, null);
    try {
      const r = await pc(parent.token, { action: "register", child: childBody(invited) });
      assertEquals(r.status, 409);
      assertEquals(r.json.error.code, "email_in_use");
      assertEquals(await idByEmail(svc, invited), null);
    } finally {
      await svc.from("pending_invites").delete().eq("email", invited);
    }

    // A password in the body is ignored: the child still cannot sign in with it.
    const withPw = childEmail();
    assertEquals((await pc(parent.token, { action: "register", child: childBody(withPw, { password: "Parent-Chosen-1" }) })).status, 200);
    const { error: pwErr } = await anon().auth.signInWithPassword({ email: withPw, password: "Parent-Chosen-1" });
    assert(pwErr, "a parent-supplied password is not applied");

    // Duplicate: an existing account (any case) -> 409 email_in_use, nothing changed.
    const dup = await pc(parent.token, { action: "register", child: childBody(student.email.toUpperCase()) });
    assertEquals(dup.status, 409);
    assertEquals(dup.json.error.code, "email_in_use");
    assertEquals((await profileOf(svc, student.id))!.role, "student");
  });
});

Deno.test("parent-child register: 6th registration inside 15 minutes -> 429", async () => {
  await withScenario(async ({ svc, track, childEmail }) => {
    const parent = track(await createTestUser(svc, { role: "parent", status: "active" }));
    for (let i = 0; i < 5; i++) {
      const r = await pc(parent.token, { action: "register", child: childBody(childEmail()) });
      assertEquals(r.status, 200, `registration ${i + 1}`);
    }
    const e6 = childEmail();
    const r = await pc(parent.token, { action: "register", child: childBody(e6) });
    assertEquals(r.status, 429);
    assertEquals(r.json.error.code, "rate_limited");
    assertEquals(await idByEmail(svc, e6), null);
  });
});
