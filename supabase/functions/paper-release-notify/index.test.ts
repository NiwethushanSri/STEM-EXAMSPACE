import { assert, assertEquals } from "jsr:@std/assert@1";
import { call, type Fixture, makePdf, setup } from "../_shared/paper/test_fixtures.ts";
import { env } from "../_shared/test_helpers.ts";

const notify = (secret: string | null): Promise<Response> =>
  fetch(`${env("SUPABASE_URL")}/functions/v1/paper-release-notify`, {
    method: "POST",
    headers: {
      apikey: env("SUPABASE_ANON_KEY"),
      "Content-Type": "application/json",
      ...(secret === null ? {} : { "x-cron-secret": secret }),
    },
    body: "{}",
  });

interface Report {
  released: { exam_id: string; sent: number }[];
  corrected: { exam_id: string; sent: number }[];
}
const run = async (): Promise<Report> => {
  const res = await notify(env("CRON_SECRET"));
  assertEquals(res.status, 200);
  return await res.json();
};
const sentFor = (rows: { exam_id: string; sent: number }[], id: string) =>
  rows.find((r) => r.exam_id === id)?.sent ?? null;

/** Links the fixture's parent account to its student. */
async function linkParent(fx: Fixture) {
  const r = await fx.svc.from("parent_children").insert({ parent_id: fx.stranger.id, student_id: fx.student.id });
  assertEquals(r.error, null);
}
const exam = async (fx: Fixture) => {
  const r = await fx.svc.from("exams").select("release_notified_at, release_held").eq("id", fx.examId).single();
  assertEquals(r.error, null);
  return r.data!;
};

/** Marks the release notice as sent, supersedes version 1 and uploads version 2. */
async function replacePaper(fx: Fixture, v1: string) {
  const mark = await fx.svc.from("exams").update({ release_notified_at: new Date().toISOString() }).eq("id", fx.examId);
  assertEquals(mark.error, null);
  const sup = await fx.svc.from("exam_papers").update({ superseded_at: new Date().toISOString() }).eq("id", v1);
  assertEquals(sup.error, null);
  const path = await fx.upload(await makePdf(2));
  const v2 = await fx.svc.from("exam_papers").insert({
    exam_id: fx.examId,
    kind: "paper",
    title: "Question paper",
    version: 2,
    storage_path: path,
    page_count: 2,
    byte_size: 1000,
    pages_reviewed_at: new Date().toISOString(), // its page roles are checked: copies can be made
  });
  assertEquals(v2.error, null);
}

Deno.test("wrong_secret_401", async () => {
  const none = await notify(null);
  assertEquals(none.status, 401);
  await none.body?.cancel();
  const bad = await notify("not-the-secret");
  assertEquals(bad.status, 401);
  await bad.body?.cancel();
});

Deno.test("released_exam_notified_once", async () => {
  const fx = await setup(5);
  try {
    await fx.addPaper(await makePdf(2), "paper", 2);
    await linkParent(fx);
    const first = await run();
    assertEquals(sentFor(first.released, fx.examId), 2); // the candidate and the linked parent
    assert((await exam(fx)).release_notified_at);
    const second = await run();
    assertEquals(sentFor(second.released, fx.examId), null);
  } finally {
    await fx.cleanup();
  }
});

Deno.test("no_current_paper_not_notified", async () => {
  const fx = await setup(5);
  try {
    const r = await run();
    assertEquals(sentFor(r.released, fx.examId), null);
    assertEquals((await exam(fx)).release_notified_at, null);
  } finally {
    await fx.cleanup();
  }
});

Deno.test("held_exam_not_notified", async () => {
  const fx = await setup(5);
  try {
    await fx.addPaper(await makePdf(2), "paper", 2);
    const h = await fx.svc.from("exams").update({ release_held: true }).eq("id", fx.examId);
    assertEquals(h.error, null);
    const r = await run();
    assertEquals(sentFor(r.released, fx.examId), null);
    assertEquals((await exam(fx)).release_notified_at, null);
  } finally {
    await fx.cleanup();
  }
});

Deno.test("old_release_outside_window_not_notified", async () => {
  const fx = await setup(-7 * 60);
  try {
    await fx.addPaper(await makePdf(2), "paper", 2);
    const r = await run();
    assertEquals(sentFor(r.released, fx.examId), null);
    assertEquals((await exam(fx)).release_notified_at, null);
  } finally {
    await fx.cleanup();
  }
});

Deno.test("corrected_paper_notifies_downloaders_once", async () => {
  const fx = await setup(5);
  try {
    const v1 = await fx.addPaper(await makePdf(2), "paper", 2);
    await linkParent(fx);
    const dl = await call("paper-copy", fx.student.token, { bookingId: fx.bookingId, kind: "home" });
    assertEquals(dl.status, 200);
    await dl.body?.cancel();
    await replacePaper(fx, v1.id);

    const first = await run();
    assertEquals(sentFor(first.corrected, fx.examId), 2);
    const row = await fx.svc.from("exam_papers").select("corrected_notified_at").eq("id", v1.id).single();
    assert(row.data?.corrected_notified_at);
    const second = await run();
    assertEquals(sentFor(second.corrected, fx.examId), null);
  } finally {
    await fx.cleanup();
  }
});

Deno.test("replaced_paper_nobody_downloaded_sends_nothing", async () => {
  const fx = await setup(5);
  try {
    const v1 = await fx.addPaper(await makePdf(2), "paper", 2);
    await replacePaper(fx, v1.id);
    const r = await run();
    assertEquals(sentFor(r.corrected, fx.examId), 0);
  } finally {
    await fx.cleanup();
  }
});

const recipients = async (fx: Fixture, paperId: string) => {
  const r = await fx.svc.rpc("paper_corrected_recipients", { p_paper_ids: [paperId] });
  assertEquals(r.error, null);
  return (r.data ?? []) as { email: string }[];
};

async function downloaded(fx: Fixture) {
  const dl = await call("paper-copy", fx.student.token, { bookingId: fx.bookingId, kind: "home" });
  assertEquals(dl.status, 200);
  await dl.body?.cancel();
}

Deno.test("corrected_recipients_cancelled_booking_excluded", async () => {
  const fx = await setup(5);
  try {
    const v1 = await fx.addPaper(await makePdf(2), "paper", 2);
    await downloaded(fx);
    await replacePaper(fx, v1.id);
    assertEquals((await recipients(fx, v1.id)).length, 1);
    const c = await fx.svc.from("bookings").update({ status: "cancelled" }).eq("id", fx.bookingId);
    assertEquals(c.error, null);
    assertEquals((await recipients(fx, v1.id)).length, 0);
  } finally {
    await fx.cleanup();
  }
});

Deno.test("corrected_recipients_inactive_parent_excluded", async () => {
  const fx = await setup(5);
  try {
    const v1 = await fx.addPaper(await makePdf(2), "paper", 2);
    await linkParent(fx);
    await downloaded(fx);
    await replacePaper(fx, v1.id);
    assertEquals((await recipients(fx, v1.id)).length, 2);
    const s = await fx.svc.from("profiles").update({ status: "suspended" }).eq("id", fx.stranger.id);
    assertEquals(s.error, null);
    const left = await recipients(fx, v1.id);
    assertEquals(left.length, 1);
    assertEquals(left[0].email.toLowerCase(), fx.student.email.toLowerCase());
  } finally {
    await fx.cleanup();
  }
});

Deno.test("corrected_recipients_already_has_current_version_excluded", async () => {
  const fx = await setup(5);
  try {
    const v1 = await fx.addPaper(await makePdf(2), "paper", 2);
    await downloaded(fx);
    await replacePaper(fx, v1.id);
    assertEquals((await recipients(fx, v1.id)).length, 1);
    await downloaded(fx);
    assertEquals((await recipients(fx, v1.id)).length, 0);
  } finally {
    await fx.cleanup();
  }
});
