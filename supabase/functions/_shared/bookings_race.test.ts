import { assert, assertEquals } from "jsr:@std/assert@1";
import { createTestUser, deleteUsers, service, type TestUser } from "./test_helpers.ts";

Deno.test("last_seat_race", async () => {
  const svc = service();
  const users: TestUser[] = [];
  let subjectId: number | null = null;
  let examId: string | null = null;
  try {
    const a = await createTestUser(svc, { role: "student", status: "active" });
    users.push(a);
    const b = await createTestUser(svc, { role: "student", status: "active" });
    users.push(b);

    const subj = await svc.from("subjects").insert({ name: `ZZ Race ${crypto.randomUUID()}`, kind: "school" })
      .select("id").single();
    assertEquals(subj.error, null);
    subjectId = subj.data!.id as number;

    const day = 24 * 3600 * 1000;
    const ex = await svc.from("exams").insert({
      subject_id: subjectId,
      title: "ZZ Race exam",
      paper: "P1",
      format: "online",
      starts_at: new Date(Date.now() + 20 * day).toISOString(),
      duration_minutes: 60,
      seat_limit: 1,
      price_pence: 500,
      price_confirmed: true,
      booking_deadline: new Date(Date.now() + 10 * day).toISOString(),
      status: "published",
    }).select("id").single();
    assertEquals(ex.error, null);
    examId = ex.data!.id as string;

    const [ra, rb] = await Promise.all([
      a.client.rpc("create_booking", { p_exam: examId, p_student: a.id }),
      b.client.rpc("create_booking", { p_exam: examId, p_student: b.id }),
    ]);
    assertEquals(ra.error, null);
    assertEquals(rb.error, null);
    const results = [ra.data, rb.data] as Array<{ ok: boolean; code?: string }>;
    assertEquals(results.filter((r) => r.ok).length, 1, "exactly one booking succeeds");
    const loser = results.find((r) => !r.ok);
    assert(loser);
    assertEquals(loser.code, "fully_booked");

    const rows = await svc.from("bookings").select("id").eq("exam_id", examId);
    assertEquals(rows.data?.length, 1);
  } finally {
    if (examId) await svc.from("bookings").delete().eq("exam_id", examId);
    if (examId) await svc.from("exams").delete().eq("id", examId);
    if (subjectId !== null) await svc.from("subjects").delete().eq("id", subjectId);
    await deleteUsers(svc, users);
  }
});
