import { assert, assertEquals } from "jsr:@std/assert@1";
import { createTestUser, deleteUsers, service, type TestUser } from "./test_helpers.ts";

Deno.test("last_seat_race_per_centre", async () => {
  const svc = service();
  const users: TestUser[] = [];
  let subjectId: number | null = null;
  let venueId: string | null = null;
  let examId: string | null = null;
  try {
    const a = await createTestUser(svc, { role: "student", status: "active" });
    users.push(a);
    const b = await createTestUser(svc, { role: "student", status: "active" });
    users.push(b);
    const c = await createTestUser(svc, { role: "student", status: "active" });
    users.push(c);

    const subj = await svc.from("subjects").insert({ name: `ZZ Race ${crypto.randomUUID()}`, kind: "school" })
      .select("id").single();
    assertEquals(subj.error, null);
    subjectId = subj.data!.id as number;

    const venue = await svc.from("venues").insert({ name: `ZZ Race hall ${crypto.randomUUID()}`, rooms: ["A", "B"] })
      .select("id").single();
    assertEquals(venue.error, null);
    venueId = venue.data!.id as string;

    const day = 24 * 3600 * 1000;
    const ex = await svc.from("exams").insert({
      subject_id: subjectId,
      title: "ZZ Race exam",
      paper: "P1",
      format: "in_person",
      starts_at: new Date(Date.now() + 20 * day).toISOString(),
      duration_minutes: 60,
      price_pence: 500,
      price_confirmed: true,
      booking_deadline: new Date(Date.now() + 10 * day).toISOString(),
      status: "published",
    }).select("id").single();
    assertEquals(ex.error, null);
    examId = ex.data!.id as string;

    // Two centres with one seat each.
    const centres = await svc.from("exam_centres").insert([
      { exam_id: examId, venue_id: venueId, room: "A", seat_limit: 1 },
      { exam_id: examId, venue_id: venueId, room: "B", seat_limit: 1 },
    ]).select("id, room");
    assertEquals(centres.error, null);
    const centreA = centres.data!.find((r) => r.room === "A")!.id as string;
    const centreB = centres.data!.find((r) => r.room === "B")!.id as string;

    // Two families race for the last seat at centre A.
    const [ra, rb] = await Promise.all([
      a.client.rpc("create_booking", { p_exam: examId, p_student: a.id, p_centre: centreA }),
      b.client.rpc("create_booking", { p_exam: examId, p_student: b.id, p_centre: centreA }),
    ]);
    assertEquals(ra.error, null);
    assertEquals(rb.error, null);
    const results = [ra.data, rb.data] as Array<{ ok: boolean; code?: string }>;
    assertEquals(results.filter((r) => r.ok).length, 1, "exactly one booking at centre A succeeds");
    const loser = results.find((r) => !r.ok);
    assert(loser);
    assertEquals(loser.code, "centre_full");

    // Centre B still has its seat.
    const rc = await c.client.rpc("create_booking", { p_exam: examId, p_student: c.id, p_centre: centreB });
    assertEquals(rc.error, null);
    assertEquals((rc.data as { ok: boolean }).ok, true, "a third family books centre B");

    const rows = await svc.from("bookings").select("centre_id, sitting").eq("exam_id", examId);
    assertEquals(rows.error, null);
    assertEquals(rows.data?.filter((r) => r.centre_id === centreA).length, 1, "one booking at centre A");
    assertEquals(rows.data?.filter((r) => r.centre_id === centreB).length, 1, "one booking at centre B");
    assert(rows.data?.every((r) => r.sitting === "centre"));
  } finally {
    if (examId) await svc.from("bookings").delete().eq("exam_id", examId);
    if (examId) await svc.from("exams").delete().eq("id", examId);
    if (venueId) await svc.from("venues").delete().eq("id", venueId);
    if (subjectId !== null) await svc.from("subjects").delete().eq("id", subjectId);
    await deleteUsers(svc, users);
  }
});
