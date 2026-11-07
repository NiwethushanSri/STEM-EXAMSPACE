import { assert, assertEquals } from "jsr:@std/assert@1";
import { createTestUser, pc, withScenario } from "./_helpers.ts";
import type { Svc, TestUser } from "./_helpers.ts";

const uniqueIndex = () => `SE-2097-${String(1000 + Math.floor(Math.random() * 9000))}`;

/** An approved student with a known index and date of birth. */
async function approvedChild(svc: Svc, track: (u: TestUser) => TestUser, dob = "2010-06-15") {
  const s = track(await createTestUser(svc, { role: "student", status: "active" }));
  const index = uniqueIndex();
  const { error } = await svc.from("student_details").update({ index_number: index, date_of_birth: dob }).eq("profile_id", s.id);
  if (error) throw new Error(`setup failed: ${error.code}`);
  return { s, index };
}

Deno.test("parent-child link: correct match -> request only; admin approves -> parent reads child; reject -> no link", async () => {
  await withScenario(async ({ svc, track, trackKey }) => {
    const parent = track(await createTestUser(svc, { role: "parent", status: "active" }));
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const a = await approvedChild(svc, track);
    const b = await approvedChild(svc, track, "2012-01-20");
    trackKey(`pidx:${a.index}`);
    trackKey(`pidx:${b.index}`);

    // Index casing / spacing is normalised like index-login.
    const r = await pc(parent.token, { action: "link", indexNumber: ` ${a.index.toLowerCase()} `, dateOfBirth: "2010-06-15" });
    assertEquals(r.status, 200);
    assertEquals(r.json, { requested: true });
    const { data: reqs } = await svc.from("parent_link_requests").select("id, student_id").eq("parent_id", parent.id);
    assertEquals(reqs!.length, 1);
    assertEquals(reqs![0].student_id, a.s.id);
    const { count: aud } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "parent_link_requested").eq("actor_id", parent.id).eq("target_id", a.s.id);
    assertEquals(aud, 1);
    const { count: links } = await svc.from("parent_children").select("*", { count: "exact", head: true }).eq("parent_id", parent.id);
    assertEquals(links, 0);
    const { data: seen } = await parent.client.from("profiles").select("id").eq("id", a.s.id);
    assertEquals((seen ?? []).length, 0, "request alone gives no access");
    const { data: own } = await parent.client.from("parent_link_requests").select("id");
    assertEquals((own ?? []).length, 1, "parent reads own request");

    // Repeating is idempotent.
    assertEquals((await pc(parent.token, { action: "link", indexNumber: a.index, dateOfBirth: "2010-06-15" })).status, 200);
    const { count: again } = await svc.from("parent_link_requests").select("*", { count: "exact", head: true }).eq("parent_id", parent.id);
    assertEquals(again, 1);

    // Non-admins cannot decide.
    const reqId = reqs![0].id;
    assertEquals((await pc(tutor.token, { action: "approve_link", requestId: reqId })).status, 403);
    assertEquals((await pc(parent.token, { action: "approve_link", requestId: reqId })).status, 403);
    assertEquals((await pc(admin.token, { action: "approve_link", requestId: "nope" })).status, 400);
    assertEquals((await pc(admin.token, { action: "approve_link", requestId: crypto.randomUUID() })).status, 404);

    const ap = await pc(admin.token, { action: "approve_link", requestId: reqId });
    assertEquals(ap.status, 200);
    const { data: seen2 } = await parent.client.from("profiles").select("id").eq("id", a.s.id);
    assertEquals((seen2 ?? []).length, 1, "approved: parent reads child");
    const { count: gone } = await svc.from("parent_link_requests").select("*", { count: "exact", head: true }).eq("id", reqId);
    assertEquals(gone, 0);
    // A decided request cannot be decided again.
    assertEquals((await pc(admin.token, { action: "approve_link", requestId: reqId })).status, 404);
    // Already linked: still the same 200.
    assertEquals((await pc(parent.token, { action: "link", indexNumber: a.index, dateOfBirth: "2010-06-15" })).json, { requested: true });
    const { count: noNew } = await svc.from("parent_link_requests").select("*", { count: "exact", head: true }).eq("parent_id", parent.id);
    assertEquals(noNew, 0, "an existing link produces no new request");

    // Reject path.
    assertEquals((await pc(parent.token, { action: "link", indexNumber: b.index, dateOfBirth: "2012-01-20" })).status, 200);
    const { data: r2 } = await svc.from("parent_link_requests").select("id").eq("parent_id", parent.id).eq("student_id", b.s.id).single();
    assertEquals((await pc(tutor.token, { action: "reject_link", requestId: r2!.id })).status, 403);
    assertEquals((await pc(admin.token, { action: "reject_link", requestId: r2!.id })).status, 200);
    const { data: seen3 } = await parent.client.from("profiles").select("id").eq("id", b.s.id);
    assertEquals((seen3 ?? []).length, 0, "rejected: no access");
    const { count: l2 } = await svc.from("parent_children").select("*", { count: "exact", head: true })
      .eq("parent_id", parent.id).eq("student_id", b.s.id);
    assertEquals(l2, 0);
  });
});

Deno.test("parent-child link: wrong DOB and unknown index give identical 404; 6th attempt -> 429; pending child never matches", async () => {
  await withScenario(async ({ svc, track, trackKey }) => {
    const parent = track(await createTestUser(svc, { role: "parent", status: "active" }));
    const student = track(await createTestUser(svc, { role: "student", status: "pending" }));
    const a = await approvedChild(svc, track);
    const ghost = "SE-2096-0001";
    trackKey(`pidx:${a.index}`);
    trackKey(`pidx:${ghost}`);
    const pendingIndex = uniqueIndex();
    trackKey(`pidx:${pendingIndex}`);
    await svc.from("student_details").update({ index_number: pendingIndex, date_of_birth: "2010-06-15" }).eq("profile_id", student.id);

    const wrongDob = await pc(parent.token, { action: "link", indexNumber: a.index, dateOfBirth: "2010-06-16" });
    const unknown = await pc(parent.token, { action: "link", indexNumber: ghost, dateOfBirth: "2010-06-15" });
    const pending = await pc(parent.token, { action: "link", indexNumber: pendingIndex, dateOfBirth: "2010-06-15" });
    for (const r of [wrongDob, unknown, pending]) {
      assertEquals(r.status, 404);
      assertEquals(r.json, { error: { code: "not_found", message: "We could not find a child with those details" } });
    }
    assertEquals(JSON.stringify(wrongDob.json), JSON.stringify(unknown.json));
    const { count } = await svc.from("parent_link_requests").select("*", { count: "exact", head: true }).eq("parent_id", parent.id);
    assertEquals(count, 0);

    // Bad shape is a 400 and does not count.
    assertEquals((await pc(parent.token, { action: "link", indexNumber: "", dateOfBirth: "2010-06-15" })).status, 400);
    assertEquals((await pc(parent.token, { action: "link", indexNumber: a.index, dateOfBirth: "15/06/2010" })).status, 400);

    // 3 failures so far; two more still answer 404, the 6th is limited.
    assertEquals((await pc(parent.token, { action: "link", indexNumber: ghost, dateOfBirth: "2010-06-14" })).status, 404);
    assertEquals((await pc(parent.token, { action: "link", indexNumber: ghost, dateOfBirth: "2010-06-13" })).status, 404);
    const limited = await pc(parent.token, { action: "link", indexNumber: ghost, dateOfBirth: "2010-06-12" });
    assertEquals(limited.status, 429);
    assertEquals(limited.json.error.code, "rate_limited");
    // Even the correct combination is refused while limited, and creates nothing.
    assertEquals((await pc(parent.token, { action: "link", indexNumber: a.index, dateOfBirth: "2010-06-15" })).status, 429);
    const { count: after } = await svc.from("parent_link_requests").select("*", { count: "exact", head: true }).eq("parent_id", parent.id);
    assertEquals(after, 0);
  });
});

Deno.test("parent-child link: non-parent callers are 403", async () => {
  await withScenario(async ({ svc, track }) => {
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const a = await approvedChild(svc, track);
    const r = await pc(tutor.token, { action: "link", indexNumber: a.index, dateOfBirth: "2010-06-15" });
    assertEquals(r.status, 403);
    assert((await svc.from("parent_link_requests").select("id").eq("student_id", a.s.id)).data!.length === 0);
  });
});
