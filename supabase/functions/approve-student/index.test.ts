import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { createTestUser, deleteUserIds, deleteUsers, env, service, type TestUser } from "../_shared/test_helpers.ts";

const url = () => `${env("SUPABASE_URL")}/functions/v1/approve-student`;

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

/** Creates a pending student whose signup parent email is the given one. */
async function pendingStudent(svc: ReturnType<typeof service>, parentEmail: string): Promise<TestUser> {
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
  svc: ReturnType<typeof service>;
  admin: TestUser;
  track: (u: TestUser) => TestUser;
  parentEmail: string;
}) => Promise<void>) {
  const svc = service();
  const users: TestUser[] = [];
  const parentEmail = `t7-parent-${crypto.randomUUID()}@example.test`;
  try {
    const admin = await createTestUser(svc, { role: "admin", status: "active" });
    users.push(admin);
    await fn({ svc, admin, track: (u) => (users.push(u), u), parentEmail });
  } finally {
    // Parents created by the function are not in `users`: find them by email.
    const { data } = await svc.from("profiles").select("id").eq("email", parentEmail);
    const extra = (data ?? []).map((r: { id: string }) => r.id);
    await svc.from("pending_invites").delete().eq("email", parentEmail);
    await deleteUsers(svc, users);
    await deleteUserIds(svc, extra);
  }
}

Deno.test("approve-student: student caller -> 403", async () => {
  await withScenario(async ({ svc, track, parentEmail }) => {
    const student = track(await pendingStudent(svc, parentEmail));
    const r = await call(student.token, { studentId: student.id });
    assertEquals(r.status, 403);
    assertEquals(r.json.error.code, "forbidden");
  });
});

Deno.test("approve-student: invalid studentId -> 400 invalid_input", async () => {
  await withScenario(async ({ admin }) => {
    for (const body of [{}, { studentId: "nope" }, { studentId: 5 }]) {
      const r = await call(admin.token, body);
      assertEquals(r.status, 400);
      assertEquals(r.json.error.code, "invalid_input");
    }
  });
});

Deno.test("approve-student: admin approves, creates parent, links; sibling reuses parent; twice -> 409", async () => {
  await withScenario(async ({ svc, admin, track, parentEmail }) => {
    const s1 = track(await pendingStudent(svc, parentEmail));
    const r1 = await call(admin.token, { studentId: s1.id });
    assertEquals(r1.status, 200);
    assert(/^SE-\d{4}-\d{4}$/.test(r1.json.indexNumber), `bad index ${r1.json.indexNumber}`);
    assertEquals(r1.json.parentInvited, true);
    assertEquals(typeof r1.json.emailsSent, "boolean");
    assert(!JSON.stringify(r1.json).includes("token"), "response must not carry the invite token");

    const { data: prof } = await svc.from("profiles").select("status, index:student_details(index_number)").eq("id", s1.id).single();
    assertEquals(prof!.status, "profile_incomplete");

    const { data: parents } = await svc.from("profiles").select("id, role, status").eq("email", parentEmail);
    assertEquals(parents!.length, 1);
    assertEquals(parents![0].role, "parent");
    assertEquals(parents![0].status, "active");
    const parentId = parents![0].id;
    const { data: links } = await svc.from("parent_children").select("student_id").eq("parent_id", parentId);
    assertEquals(links!.map((l: { student_id: string }) => l.student_id), [s1.id]);
    const { count } = await svc.from("pending_invites").select("*", { count: "exact", head: true }).eq("email", parentEmail);
    assertEquals(count, 0);

    // Sibling with the same parent email (different casing).
    const s2 = track(await pendingStudent(svc, `  ${parentEmail.toUpperCase()} `));
    const r2 = await call(admin.token, { studentId: s2.id });
    assertEquals(r2.status, 200);
    assertEquals(r2.json.parentInvited, false);
    assertNotEquals(r2.json.indexNumber, r1.json.indexNumber);
    const { data: parents2 } = await svc.from("profiles").select("id").eq("email", parentEmail);
    assertEquals(parents2!.length, 1);
    const { data: links2 } = await svc.from("parent_children").select("student_id").eq("parent_id", parentId);
    assertEquals(links2!.length, 2);

    // Twice -> conflict.
    const again = await call(admin.token, { studentId: s1.id });
    assertEquals(again.status, 409);
    assertEquals(again.json.error.code, "conflict");
  });
});

Deno.test("concurrent_approvals_get_distinct_index_numbers", async () => {
  await withScenario(async ({ svc, admin, track, parentEmail }) => {
    const a = track(await pendingStudent(svc, parentEmail));
    const b = track(await pendingStudent(svc, parentEmail));
    const [ra, rb] = await Promise.all([
      call(admin.token, { studentId: a.id }),
      call(admin.token, { studentId: b.id }),
    ]);
    assertEquals(ra.status, 200);
    assertEquals(rb.status, 200);
    assertNotEquals(ra.json.indexNumber, rb.json.indexNumber);
    const { data: parents } = await svc.from("profiles").select("id").eq("email", parentEmail);
    assertEquals(parents!.length, 1);
  });
});
