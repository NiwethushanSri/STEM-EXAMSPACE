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
