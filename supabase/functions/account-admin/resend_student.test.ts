import { assert, assertEquals } from "jsr:@std/assert@1";
import { post, resend, pendingStudent, withScenario, markApproved, approvedIndex, status, createTestUser } from "./_helpers.ts";

Deno.test("account-admin: resend (b) approved student without a parent link -> parent created and linked", async () => {
  await withScenario(async ({ svc, track, parentEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const s = track(await pendingStudent(svc, `  ${parentEmail.toUpperCase()} `));
    await markApproved(svc, s.id, `SE-2098-${String(Math.floor(Math.random() * 9000) + 1000)}`);

    const r = await resend(admin.token, s.id);
    assertEquals(r.status, 200);
    assertEquals(r.json.parentLinked, true);
    assertEquals(r.json.parentInvited, true);
    assertEquals(r.json.emailSent, true);
    assert(!JSON.stringify(r.json).toLowerCase().includes("token"));

    const { data: parents } = await svc.from("profiles").select("id, role, status, invite_sent_at").eq("email", parentEmail);
    assertEquals(parents!.length, 1);
    assertEquals(parents![0].role, "parent");
    assertEquals(parents![0].status, "active");
    assert(parents![0].invite_sent_at);
    const { data: links } = await svc.from("parent_children").select("student_id").eq("parent_id", parents![0].id);
    assertEquals(links!.map((l: { student_id: string }) => l.student_id), [s.id]);
    const { count } = await svc.from("pending_invites").select("*", { count: "exact", head: true }).eq("email", parentEmail);
    assertEquals(count, 0);

    // Linked now: a second resend is a conflict.
    const again = await resend(admin.token, s.id);
    assertEquals(again.status, 409);
  });
});

Deno.test("account-admin: resend (b) heals a token-bearing parent shell left by a crash", async () => {
  await withScenario(async ({ svc, track, parentEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const s = track(await pendingStudent(svc, parentEmail));
    await markApproved(svc, s.id, `SE-2098-${String(Math.floor(Math.random() * 9000) + 1000)}`);
    // Simulate the crash: invite row + auth user carrying the token, never claimed.
    const { data: inv, error: iErr } = await svc.from("pending_invites")
      .insert({ email: parentEmail, role: "parent" }).select("token").single();
    assert(!iErr, "invite insert");
    const { data: created, error: cErr } = await svc.auth.admin.createUser({
      email: parentEmail,
      email_confirm: true,
      app_metadata: { invite_token: inv!.token },
      user_metadata: { first_name: "Kamal", last_name: "Perera" },
    });
    assert(!cErr && created.user, "shell create");

    const r = await resend(admin.token, s.id);
    assertEquals(r.status, 200);
    assertEquals(r.json.parentLinked, true);
    const { data: parents } = await svc.from("profiles").select("id, role").eq("email", parentEmail);
    assertEquals(parents!.length, 1);
    assertEquals(parents![0].id, created.user!.id);
    assertEquals(parents![0].role, "parent");
  });
});

Deno.test("account-admin: resend (b) with a staff or student parent email -> 409 parent_email_is_staff, nothing hijacked", async () => {
  await withScenario(async ({ svc, track }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const other = track(await createTestUser(svc, { role: "student", status: "active" }));
    for (const owner of [tutor, other]) {
      const s = track(await pendingStudent(svc, owner.email));
      await markApproved(svc, s.id, `SE-2098-${String(Math.floor(Math.random() * 9000) + 1000)}`);
      const r = await resend(admin.token, s.id);
      assertEquals(r.status, 409);
      assertEquals(r.json.error.code, "parent_email_is_staff");
      const { count } = await svc.from("parent_children").select("*", { count: "exact", head: true }).eq("student_id", s.id);
      assertEquals(count, 0);
    }
    const { data: t } = await svc.from("profiles").select("role").eq("id", tutor.id).single();
    assertEquals(t!.role, "tutor");
    const { data: o } = await svc.from("profiles").select("role").eq("id", other.id).single();
    assertEquals(o!.role, "student");
  });
});

Deno.test("account-admin: resend (c) two siblings, both unlinked -> resend for one links both to the single parent", async () => {
  await withScenario(async ({ svc, track, parentEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const s1 = track(await pendingStudent(svc, parentEmail));
    const s2 = track(await pendingStudent(svc, `  ${parentEmail.toUpperCase()}`));
    for (const s of [s1, s2]) {
      const a = await post("approve-student", admin.token, { studentId: s.id });
      assertEquals(a.status, 200);
    }
    const { data: parents } = await svc.from("profiles").select("id").eq("email", parentEmail);
    assertEquals(parents!.length, 1);
    const parentId = parents![0].id;
    const { count: before } = await svc.from("parent_children").select("*", { count: "exact", head: true }).eq("parent_id", parentId);
    assertEquals(before, 2);

    // Simulate the crash: both links lost.
    const { error: dErr } = await svc.from("parent_children").delete().eq("parent_id", parentId);
    assert(!dErr);

    const r = await resend(admin.token, s1.id);
    assertEquals(r.status, 200);
    assertEquals(r.json.parentLinked, true);
    assertEquals(r.json.parentInvited, false);
    const { data: links } = await svc.from("parent_children").select("student_id").eq("parent_id", parentId);
    assertEquals(links!.map((l: { student_id: string }) => l.student_id).sort(), [s1.id, s2.id].sort());
    const { data: after } = await svc.from("profiles").select("id").eq("email", parentEmail);
    assertEquals(after!.length, 1);
  });
});

Deno.test("account-admin: resend (b) audits invite_resent for the student", async () => {
  await withScenario(async ({ svc, track, parentEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const s = track(await pendingStudent(svc, parentEmail));
    await markApproved(svc, s.id, approvedIndex());
    assertEquals((await resend(admin.token, s.id)).status, 200);
    const { count } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "invite_resent").eq("target_id", s.id).eq("actor_id", admin.id);
    assertEquals(count, 1);
  });
});

Deno.test("account-admin: resend (b) with a pending non-parent invite for the email -> 409, nothing created", async () => {
  await withScenario(async ({ svc, track, parentEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const s = track(await pendingStudent(svc, parentEmail));
    await markApproved(svc, s.id, approvedIndex());
    const { error } = await svc.from("pending_invites").insert({ email: parentEmail, role: "admin" });
    assert(!error);
    const r = await resend(admin.token, s.id);
    assertEquals(r.status, 409);
    assertEquals(r.json.error.code, "parent_email_is_staff");
    const { data: inv } = await svc.from("pending_invites").select("role").eq("email", parentEmail).single();
    assertEquals(inv!.role, "admin");
    const { data: ps } = await svc.from("profiles").select("id").eq("email", parentEmail);
    assertEquals(ps!.length, 0);
    const { count: audits } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "invite_resent").eq("target_id", s.id);
    assertEquals(audits, 0);
  });
});

Deno.test("account-admin: resend (b) refuses a student shell whose token does not match the invite", async () => {
  await withScenario(async ({ svc, track, parentEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const s = track(await pendingStudent(svc, parentEmail));
    await markApproved(svc, s.id, approvedIndex());
    const { error } = await svc.from("pending_invites").insert({ email: parentEmail, role: "parent" });
    assert(!error);
    // A student sign-up with the parent email whose app_metadata token is NOT the invite's.
    const { data: shell, error: cErr } = await svc.auth.admin.createUser({
      email: parentEmail,
      email_confirm: true,
      app_metadata: { invite_token: crypto.randomUUID() },
    });
    assert(!cErr && shell.user);
    const r = await resend(admin.token, s.id);
    assertEquals(r.status, 409);
    assertEquals(r.json.error.code, "parent_email_is_staff");
    const { data: p } = await svc.from("profiles").select("role").eq("id", shell.user!.id).single();
    assertEquals(p!.role, "student");
  });
});

Deno.test("account-admin: resend (b) with an empty parent email -> 409 conflict", async () => {
  await withScenario(async ({ svc, track, parentEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const s = track(await pendingStudent(svc, parentEmail));
    await markApproved(svc, s.id, approvedIndex());
    await svc.from("student_details").update({ signup_parent_email: "  " }).eq("profile_id", s.id);
    const r = await resend(admin.token, s.id);
    assertEquals(r.status, 409);
    assertEquals(r.json.error.code, "conflict");
  });
});

Deno.test("account-admin: resend (b) with a suspended parent -> not linked, warning, not audited", async () => {
  await withScenario(async ({ svc, track, parentEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const s = track(await pendingStudent(svc, parentEmail));
    await markApproved(svc, s.id, approvedIndex());
    const { data: u, error } = await svc.auth.admin.createUser({ email: parentEmail, email_confirm: true });
    assert(!error && u.user);
    await svc.from("profiles").update({ role: "parent", status: "suspended" }).eq("id", u.user!.id);
    await svc.from("student_details").delete().eq("profile_id", u.user!.id);
    const r = await resend(admin.token, s.id);
    assertEquals(r.status, 200);
    assertEquals(r.json.parentLinked, false);
    assertEquals(r.json.warning, "parent_suspended");
    const { count } = await svc.from("parent_children").select("*", { count: "exact", head: true }).eq("student_id", s.id);
    assertEquals(count, 0);
    const { count: audits } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "invite_resent").eq("target_id", s.id);
    assertEquals(audits, 0);
  });
});
