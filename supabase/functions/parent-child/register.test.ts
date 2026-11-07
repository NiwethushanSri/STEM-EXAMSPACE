import { assert, assertEquals } from "jsr:@std/assert@1";
import { anon, childBody, createTestUser, idByEmail, pc, post, profileOf, userGone, withScenario } from "./_helpers.ts";

/** The real path: a recovery token verified by a fresh anon client, then the child chooses a password. */
async function setupViaLink(svc: ReturnType<typeof import("./_helpers.ts").service>, id: string, email: string, setPassword = true) {
  const { data: gl, error: glErr } = await svc.auth.admin.generateLink({ type: "recovery", email });
  assertEquals(glErr, null);
  const hashed = gl!.properties!.hashed_token;
  assert(hashed, "hashed_token present");
  const client = anon();
  const { data: v, error: vErr } = await client.auth.verifyOtp({ type: "recovery", token_hash: hashed });
  assertEquals(vErr, null, "recovery token verifies");
  assert(v.session, "verify returns a session");
  const { data: au } = await svc.auth.admin.getUserById(id);
  assert(au.user?.email_confirmed_at, "email_confirmed_at is set by verifying the link");
  assertEquals((await profileOf(svc, id))!.status, "pending", "trigger moved the child to pending");
  if (!setPassword) return;
  const password = `Child-${crypto.randomUUID()}`;
  const { error: upErr } = await client.auth.updateUser({ password });
  assertEquals(upErr, null, "child can set a password on the link session");
  const { data: si, error: siErr } = await anon().auth.signInWithPassword({ email, password });
  assertEquals(siErr, null);
  assert(si.session, "child signs in with the chosen password");
}

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

    // The parent cannot see the child before approval.
    const { data: seen } = await parent.client.from("profiles").select("id").eq("id", cid!);
    assertEquals((seen ?? []).length, 0);

    await setupViaLink(svc, cid!, e1);

    // The account is confirmed and has its own password: guessed passwords still fail.
    const probe = anon();
    for (const pw of ["Password123!", "x".repeat(12)]) {
      const { data: si, error: siErr } = await probe.auth.signInWithPassword({ email: e1, password: pw });
      assert(siErr && !si.session, "child cannot sign in with a guessed password");
    }
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
    await setupViaLink(svc, cid2, e2);
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
    const withPwId = (await idByEmail(svc, withPw))!;
    await setupViaLink(svc, withPwId, withPw, false); // confirmed, but the child set no password
    const { data: pwSi, error: pwErr } = await anon().auth.signInWithPassword({ email: withPw, password: "Parent-Chosen-1" });
    assert(pwErr && !pwSi.session, "a parent-supplied password is not applied");

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

Deno.test("parent-child register: public sign-up cannot set the child's password (observed GoTrue behaviour recorded)", async () => {
  await withScenario(async ({ svc, track, childEmail }) => {
    const parent = track(await createTestUser(svc, { role: "parent", status: "active" }));
    // GoTrue rejects .test domains on public sign-up (email_address_invalid), so use a domain with MX records (random, non-existent mailbox).
    const e = childEmail("gmail.com");
    assertEquals((await pc(parent.token, { action: "register", child: childBody(e) })).status, 200);
    const cid = (await idByEmail(svc, e))!;
    const before = (await svc.from("student_details")
      .select("requested_by_parent, signup_parent_email, signup_parent_name, school, date_of_birth").eq("profile_id", cid).single()).data;

    const P = `Attacker-${crypto.randomUUID()}`;
    const { data: su, error: suErr } = await anon().auth.signUp({ email: e, password: P });
    console.log(`[observed] signUp on registered unconfirmed email: error=${suErr ? `${suErr.status}/${suErr.code}` : "none"} session=${su?.session ? "yes" : "no"} user=${su?.user ? "yes" : "no"}`);

    // Nothing about the child changed.
    const after = (await svc.from("student_details")
      .select("requested_by_parent, signup_parent_email, signup_parent_name, school, date_of_birth").eq("profile_id", cid).single()).data;
    assertEquals(after, before);
    assertEquals(before!.requested_by_parent, parent.id);
    assertEquals((await profileOf(svc, cid))!.status, "unconfirmed");

    // The real recovery path, without the child choosing a password: P must not work.
    await setupViaLink(svc, cid, e, false);
    const { data: si, error: siErr } = await anon().auth.signInWithPassword({ email: e, password: P });
    assert(siErr && !si.session, "password from a public sign-up does not sign the child in");
    const after2 = (await svc.from("student_details").select("requested_by_parent, signup_parent_email").eq("profile_id", cid).single()).data;
    assertEquals(after2!.requested_by_parent, parent.id);
  });
});

Deno.test("parent-child link: child age boundaries are exact (8 to 25 inclusive)", async () => {
  await withScenario(async ({ svc, track, trackKey }) => {
    const parent = track(await createTestUser(svc, { role: "parent", status: "active" }));
    trackKey("pidx:SE-2095-0001");
    const now = new Date();
    const y = now.getUTCFullYear(), m = now.getUTCMonth(), d = now.getUTCDate();
    const iso = (dt: Date) => dt.toISOString().slice(0, 10);
    const cases: [string, string, number][] = [
      ["exactly 8 today", iso(new Date(Date.UTC(y - 8, m, d))), 404],
      ["one day short of 8", iso(new Date(Date.UTC(y - 8, m, d + 1))), 400],
      ["25 years 364 days", iso(new Date(Date.UTC(y - 26, m, d + 1))), 404],
      ["exactly 26", iso(new Date(Date.UTC(y - 26, m, d))), 400],
    ];
    for (const [label, dob, want] of cases) {
      const r = await pc(parent.token, { action: "link", indexNumber: "SE-2095-0001", dateOfBirth: dob });
      assertEquals(r.status, want, label);
    }
  });
});
