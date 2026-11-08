import { assert, assertEquals } from "jsr:@std/assert@1";
import { post, pendingStudent, withScenario, markApproved, createTestUser } from "./_helpers.ts";

const edit = (token: string, userId: string, parentEmail: unknown) =>
  post("account-admin", token, { action: "edit_parent_email", userId, parentEmail });

Deno.test("account-admin: edit_parent_email - allowed and refused targets, audit row", async () => {
  await withScenario(async ({ svc, track, parentEmail }) => {
    const admin = track(await createTestUser(svc, { role: "admin", status: "active" }));
    const tutor = track(await createTestUser(svc, { role: "tutor", status: "active" }));
    const pending = track(await pendingStudent(svc, `old-${parentEmail}`));
    const approved = track(await pendingStudent(svc, `old2-${parentEmail}`));
    await markApproved(svc, approved.id, `SE-2098-${String(Math.floor(Math.random() * 9000) + 1000)}`);
    const linked = track(await pendingStudent(svc, `old3-${parentEmail}`));
    await markApproved(svc, linked.id, `SE-2097-${String(Math.floor(Math.random() * 9000) + 1000)}`);
    const parent = track(await createTestUser(svc, { role: "parent", status: "active" }));
    await svc.from("parent_children").insert({ parent_id: parent.id, student_id: linked.id });

    const r = await edit(admin.token, pending.id, `  ${parentEmail.toUpperCase()} `);
    assertEquals(r.status, 200);
    assertEquals(r.json, { updated: true });
    const { data } = await svc.from("student_details").select("signup_parent_email").eq("profile_id", pending.id).single();
    assertEquals(data!.signup_parent_email, parentEmail.toLowerCase());
    const { count } = await svc.from("audit_log").select("*", { count: "exact", head: true })
      .eq("action", "parent_email_edited").eq("target_id", pending.id).eq("actor_id", admin.id).eq("target_type", "profile");
    assertEquals(count, 1);

    assertEquals((await edit(admin.token, approved.id, `new-${parentEmail}`)).status, 200);
    assertEquals((await edit(admin.token, linked.id, `new-${parentEmail}`)).status, 409);
    assertEquals((await edit(admin.token, tutor.id, `new-${parentEmail}`)).status, 409);
    const bad = await edit(admin.token, pending.id, "nope");
    assertEquals(bad.status, 400);
    assertEquals(bad.json.error.code, "invalid_input");
    assertEquals((await edit(admin.token, pending.id, 42)).status, 400);
    assertEquals((await edit(tutor.token, pending.id, `x-${parentEmail}`)).status, 403);
    const { data: after } = await svc.from("student_details").select("signup_parent_email").eq("profile_id", pending.id).single();
    assertEquals(after!.signup_parent_email, parentEmail.toLowerCase());

    // A token-bearing invite shell (no signup parent email) is refused and stays unchanged.
    const shell = track(await createTestUser(svc, { role: "student", status: "pending" }));
    await svc.from("student_details").update({ signup_parent_email: null }).eq("profile_id", shell.id);
    assertEquals((await edit(admin.token, shell.id, `shell-${parentEmail}`)).status, 409);
    const { data: sd } = await svc.from("student_details").select("signup_parent_email").eq("profile_id", shell.id).single();
    assertEquals(sd!.signup_parent_email, null);
    assert(true);
  });
});
