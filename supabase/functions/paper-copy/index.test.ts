import { assert, assertEquals } from "jsr:@std/assert@1";
import { call, type Fixture, makePdf, setup } from "../_shared/paper/test_fixtures.ts";

const downloads = async (fx: Fixture) => {
  const c = await fx.svc.from("paper_copies").select("id").eq("booking_id", fx.bookingId);
  const ids = (c.data ?? []).map((r) => r.id as string);
  if (!ids.length) return 0;
  const d = await fx.svc.from("paper_downloads").select("id").in("copy_id", ids);
  return d.data?.length ?? 0;
};

Deno.test("copy_before_release_is_409", async () => {
  const fx = await setup(24 * 60);
  try {
    await fx.addPaper(await makePdf(2), "paper", 2);
    const res = await call("paper-copy", fx.student.token, { bookingId: fx.bookingId, kind: "home" });
    assertEquals(res.status, 409);
    assertEquals((await res.json()).error.code, "paper_not_released");
    assertEquals(await downloads(fx), 0);
  } finally {
    await fx.cleanup();
  }
});

Deno.test("copy_after_release_is_pdf_and_logged", async () => {
  const fx = await setup(5);
  try {
    await fx.addPaper(await makePdf(2), "paper", 2);
    const res = await call("paper-copy", fx.student.token, { bookingId: fx.bookingId, kind: "home" });
    assertEquals(res.status, 200);
    assertEquals(res.headers.get("content-type"), "application/pdf");
    const disp = res.headers.get("content-disposition") ?? "";
    assertEquals(disp, `attachment; filename="${fx.examCode}-${fx.indexNumber}.pdf"`);
    assertEquals(res.headers.get("x-paper-differs"), "0");
    assertEquals(res.headers.get("x-paper-version"), "1"); // the version this copy was made from
    const expose = (res.headers.get("access-control-expose-headers") ?? "").toLowerCase();
    assert(
      expose.includes("content-disposition") && expose.includes("x-paper-differs") && expose.includes("x-paper-version"),
      expose,
    );
    const bytes = new Uint8Array(await res.arrayBuffer());
    assertEquals(new TextDecoder().decode(bytes.slice(0, 4)), "%PDF");
    const log = await fx.svc.from("paper_downloads").select("kind, downloaded_by, paper_copies!inner(booking_id)")
      .eq("paper_copies.booking_id", fx.bookingId);
    assertEquals(log.error, null);
    assertEquals(log.data?.length, 1);
    assertEquals(log.data![0].kind, "home");
    assertEquals(log.data![0].downloaded_by, fx.student.id);
  } finally {
    await fx.cleanup();
  }
});

Deno.test("no_copy_until_page_roles_are_checked", async () => {
  const fx = await setup(5);
  try {
    const paper = await fx.addPaper(await makePdf(2), "paper", 2, undefined, false);
    const family = await call("paper-copy", fx.student.token, { bookingId: fx.bookingId, kind: "home" });
    assertEquals(family.status, 409);
    const told = (await family.json()).error;
    assertEquals(told.code, "roles_not_reviewed");
    assertEquals(told.message, "Your paper is not ready yet. Please contact the institution.");
    assertEquals(await downloads(fx), 0);
    // The admin's own preview and the sample copy still work: that is how the roles are checked.
    const preview = await call("paper-copy", fx.admin.token, { bookingId: fx.bookingId, kind: "admin_preview" });
    assertEquals(preview.status, 200);
    await preview.arrayBuffer();
    const sample = await call("paper-copy", fx.admin.token, { paperId: paper.id, kind: "admin_sample" });
    assertEquals(sample.status, 200);
    await sample.arrayBuffer();

    const done = await fx.svc.from("exam_papers").update({ pages_reviewed_at: new Date().toISOString() }).eq("id", paper.id);
    assertEquals(done.error, null);
    const res = await call("paper-copy", fx.student.token, { bookingId: fx.bookingId, kind: "home" });
    assertEquals(res.status, 200);
    await res.arrayBuffer();
  } finally {
    await fx.cleanup();
  }
});

Deno.test("failed_build_is_not_logged", async () => {
  const fx = await setup(5);
  try {
    await fx.addPaper(new TextEncoder().encode("this is not a pdf"), "paper", 1);
    const res = await call("paper-copy", fx.student.token, { bookingId: fx.bookingId, kind: "home" });
    assertEquals(res.status, 422);
    assertEquals((await res.json()).error.message, "The paper could not be prepared. Please try again.");
    assertEquals(await downloads(fx), 0);
  } finally {
    await fx.cleanup();
  }
});

Deno.test("other_parent_forbidden", async () => {
  const fx = await setup(5);
  try {
    await fx.addPaper(await makePdf(1), "paper", 1);
    const res = await call("paper-copy", fx.stranger.token, { bookingId: fx.bookingId, kind: "home" });
    assertEquals(res.status, 403);
    assertEquals((await res.json()).error.code, "forbidden");
    assertEquals(await downloads(fx), 0);
  } finally {
    await fx.cleanup();
  }
});

Deno.test("insert_download_after_release", async () => {
  const fx = await setup(5);
  try {
    const insertBytes = await makePdf(1);
    const ins = await fx.addPaper(insertBytes, "insert", 1, "Formula sheet");
    const res = await call("paper-copy", fx.student.token, { bookingId: fx.bookingId, insertId: ins.id });
    assertEquals(res.status, 200);
    assertEquals(res.headers.get("x-paper-version"), null); // an insert is not a versioned copy
    assertEquals(new Uint8Array(await res.arrayBuffer()), insertBytes);
    const stranger = await call("paper-copy", fx.stranger.token, { bookingId: fx.bookingId, insertId: ins.id });
    assertEquals(stranger.status, 403);
  } finally {
    await fx.cleanup();
  }
});

Deno.test("admin_sample_for_admin_only", async () => {
  const fx = await setup(24 * 60);
  try {
    const paper = await fx.addPaper(await makePdf(2), "paper", 2);
    const asStudent = await call("paper-copy", fx.student.token, { paperId: paper.id, kind: "admin_sample" });
    assertEquals(asStudent.status, 403);
    assertEquals((await asStudent.json()).error.code, "forbidden");
    const asParent = await call("paper-copy", fx.stranger.token, { paperId: paper.id, kind: "admin_sample" });
    assertEquals(asParent.status, 403);
    await asParent.arrayBuffer();

    const res = await call("paper-copy", fx.admin.token, { paperId: paper.id, kind: "admin_sample" });
    assertEquals(res.status, 200);
    assertEquals(res.headers.get("content-type"), "application/pdf");
    assertEquals(res.headers.get("content-disposition"), `attachment; filename="${fx.examCode}-SAMPLE.pdf"`);
    assertEquals(res.headers.get("x-paper-version"), "1");
    const bytes = new Uint8Array(await res.arrayBuffer());
    assertEquals(new TextDecoder().decode(bytes.slice(0, 4)), "%PDF");

    const unknown = await call("paper-copy", fx.admin.token, { paperId: crypto.randomUUID(), kind: "admin_sample" });
    assertEquals(unknown.status, 404);
    await unknown.arrayBuffer();
    const badId = await call("paper-copy", fx.admin.token, { paperId: "nope", kind: "admin_sample" });
    assertEquals(badId.status, 400);
    await badId.arrayBuffer();
  } finally {
    await fx.cleanup();
  }
});

Deno.test("admin_sample_logs_nothing", async () => {
  const fx = await setup(24 * 60);
  try {
    const paper = await fx.addPaper(await makePdf(2), "paper", 2);
    const res = await call("paper-copy", fx.admin.token, { paperId: paper.id, kind: "admin_sample" });
    assertEquals(res.status, 200);
    await res.arrayBuffer();
    const copies = await fx.svc.from("paper_copies").select("id").eq("paper_id", paper.id);
    assertEquals(copies.error, null);
    assertEquals(copies.data?.length, 0);
    assertEquals(await downloads(fx), 0);
  } finally {
    await fx.cleanup();
  }
});
