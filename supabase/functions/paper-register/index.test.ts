import { assert, assertEquals } from "jsr:@std/assert@1";
import { BUCKET, call, ENCRYPTED_PDF, type Fixture, makePdf, setup } from "../_shared/paper/test_fixtures.ts";

const exists = async (fx: Fixture, path: string) => {
  const { data } = await fx.svc.storage.from(BUCKET).list(fx.examId);
  return (data ?? []).some((o) => o.name === path.split("/")[1]);
};

Deno.test("register_refuses_encrypted_and_deletes_object", async () => {
  const fx = await setup(24 * 60);
  try {
    const path = await fx.upload(ENCRYPTED_PDF);
    const res = await call("paper-register", fx.admin.token, { examId: fx.examId, kind: "paper", storagePath: path });
    assertEquals(res.status, 422);
    assertEquals((await res.json()).error.code, "paper_encrypted");
    assert(!(await exists(fx, path)), "the refused object is deleted");
    const rows = await fx.svc.from("exam_papers").select("id").eq("exam_id", fx.examId);
    assertEquals(rows.data?.length, 0);
  } finally {
    await fx.cleanup();
  }
});

Deno.test("register_accepts_a_pdf_and_never_deletes_a_registered_object", async () => {
  const fx = await setup(24 * 60);
  try {
    const p1 = await fx.upload(await makePdf(3));
    const ok = await call("paper-register", fx.admin.token, { examId: fx.examId, kind: "paper", storagePath: p1 });
    assertEquals(ok.status, 200);
    const body = await ok.json();
    assertEquals(body.version, 1);
    assertEquals(body.pageCount, 3);
    assert(typeof body.paperId === "string");
    // Registering the same object again is refused and must not delete the registered object.
    const dup = await call("paper-register", fx.admin.token, { examId: fx.examId, kind: "paper", storagePath: p1 });
    assertEquals(dup.status, 409);
    assert(await exists(fx, p1), "a registered object is never deleted");
  } finally {
    await fx.cleanup();
  }
});

Deno.test("register_non_admin_forbidden", async () => {
  const fx = await setup(24 * 60);
  try {
    const path = await fx.upload(await makePdf(1));
    const res = await call("paper-register", fx.student.token, { examId: fx.examId, kind: "paper", storagePath: path });
    assertEquals(res.status, 403);
    assert(await exists(fx, path), "a refused non-admin request leaves the object alone");
  } finally {
    await fx.cleanup();
  }
});

Deno.test("register_refuses_over_500_pages_with_its_own_message", async () => {
  const fx = await setup(24 * 60);
  try {
    const path = await fx.upload(await makePdf(501));
    const res = await call("paper-register", fx.admin.token, { examId: fx.examId, kind: "paper", storagePath: path });
    assertEquals(res.status, 422);
    const body = await res.json();
    assertEquals(body.error.code, "invalid_input");
    assertEquals(body.error.message, "This PDF has more than 500 pages. Upload a PDF of at most 500 pages.");
    assert(!(await exists(fx, path)), "the refused object is deleted");
    const rows = await fx.svc.from("exam_papers").select("id").eq("exam_id", fx.examId);
    assertEquals(rows.data?.length, 0);
  } finally {
    await fx.cleanup();
  }
});
