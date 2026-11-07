import { assert, assertEquals } from "jsr:@std/assert@1";
import { createTestUser, deleteUserIds, deleteUsers, env, service, type TestUser } from "../_shared/test_helpers.ts";

type Svc = ReturnType<typeof service>;

async function post(fn: string, token: string, body: unknown): Promise<{ status: number; json: any }> {
  const res = await fetch(`${env("SUPABASE_URL")}/functions/v1/${fn}`, {
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
const resend = (token: string, userId: string) => post("account-admin", token, { action: "resend_invite", userId });

/** A pending student with signup parent details (approve-student turns it into an approved one). */
async function pendingStudent(svc: Svc, parentEmail: string): Promise<TestUser> {
  const u = await createTestUser(svc, { role: "student", status: "pending" });
  const { error } = await svc.from("student_details").update({
    signup_parent_name: "Kamal Perera",
    signup_parent_email: parentEmail,
  }).eq("profile_id", u.id);
  if (error) {
    await deleteUsers(svc, [u]);
    throw new Error(`student_details update failed: ${error.message}`);
  }
  return u;
}

async function withScenario(fn: (ctx: {
  svc: Svc;
  track: (u: TestUser) => TestUser;
  parentEmail: string;
}) => Promise<void>) {
  const svc = service();
  const users: TestUser[] = [];
  const parentEmail = `t10a-parent-${crypto.randomUUID()}@example.test`;
  try {
    await fn({ svc, track: (u) => (users.push(u), u), parentEmail });
  } finally {
    const { data, error: selErr } = await svc.from("profiles").select("id").eq("email", parentEmail);
    const { error: invErr } = await svc.from("pending_invites").delete().eq("email", parentEmail);
    const extra = (data ?? []).map((r: { id: string }) => r.id);
    await deleteUsers(svc, users);
    await deleteUserIds(svc, extra);
    if (selErr || invErr) throw new Error(`test cleanup query failed: ${selErr?.code ?? ""} ${invErr?.code ?? ""}`);
  }
}

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

/** Approves a student directly in the database (index number + status) without touching the parent. */
async function markApproved(svc: Svc, id: string, index: string) {
  const { error: e1 } = await svc.from("student_details").update({ index_number: index }).eq("profile_id", id);
  const { error: e2 } = await svc.from("profiles").update({ status: "profile_incomplete" }).eq("id", id);
  if (e1 || e2) throw new Error("markApproved failed");
}

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

const approvedIndex = () => `SE-2098-${String(Math.floor(Math.random() * 9000) + 1000)}`;

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
