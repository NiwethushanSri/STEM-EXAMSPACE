// Test-only fixtures for the paper Edge Function suites (not a *.test.ts file).
import type { SupabaseClient } from "@supabase/supabase-js";
import { PDFDocument } from "pdf-lib";
import { createTestUser, deleteUsers, env, service, type TestUser } from "../test_helpers.ts";

export const BUCKET = "exam-papers";

export async function makePdf(pages = 2): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  for (let i = 0; i < pages; i++) doc.addPage([595, 842]).drawText(`Question page ${i + 1}`, { x: 60, y: 700 });
  return await doc.save();
}

export const ENCRYPTED_PDF = new TextEncoder().encode(`%PDF-1.6
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>
endobj
4 0 obj
<< /Filter /Standard /V 1 /R 2 /O (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) /U (bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) /P -4 >>
endobj
trailer
<< /Root 1 0 R /Size 5 /Encrypt 4 0 R >>
%%EOF
`);

export function call(name: string, token: string, body: unknown): Promise<Response> {
  return fetch(`${env("SUPABASE_URL")}/functions/v1/${name}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, apikey: env("SUPABASE_ANON_KEY"), "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

export interface Fixture {
  svc: SupabaseClient;
  admin: TestUser;
  student: TestUser;
  stranger: TestUser;
  examId: string;
  bookingId: string;
  /** Unique per run. */
  examCode: string;
  indexNumber: string;
  /** Uploads bytes at <exam>/<uuid>.pdf and returns the path. */
  upload(bytes: Uint8Array): Promise<string>;
  /** Uploads and records a paper or insert row directly (as register_exam_paper would). */
  addPaper(
    bytes: Uint8Array,
    kind: "paper" | "insert",
    pages: number,
    title?: string,
  ): Promise<{ id: string; path: string }>;
  cleanup(): Promise<void>;
}

/** An at-home exam with one paid booking. startsInMinutes 5 is already released (default 10 minute lead). */
export async function setup(startsInMinutes: number): Promise<Fixture> {
  const svc = service();
  const users: TestUser[] = [];
  const paths: string[] = [];
  let subjectId: number | null = null;
  let examId: string | null = null;
  const fx = {} as Fixture;
  const tag = crypto.randomUUID().replace(/-/g, "").slice(0, 8).toUpperCase();
  fx.examCode = `ZZ${tag}`;
  fx.indexNumber = `ZZ-${tag}`;
  try {
    fx.admin = await createTestUser(svc, { role: "admin", status: "active" });
    users.push(fx.admin);
    fx.student = await createTestUser(svc, { role: "student", status: "active" });
    users.push(fx.student);
    fx.stranger = await createTestUser(svc, { role: "parent", status: "active" });
    users.push(fx.stranger);

    const idx = await svc.from("student_details").update({ index_number: fx.indexNumber }).eq("profile_id", fx.student.id);
    if (idx.error) throw new Error(`index number: ${idx.error.message}`);

    const subj = await svc.from("subjects").insert({ name: `ZZ Fn ${crypto.randomUUID()}`, kind: "school" })
      .select("id").single();
    if (subj.error) throw new Error(`subject: ${subj.error.message}`);
    subjectId = subj.data.id as number;
    const starts = new Date(Date.now() + startsInMinutes * 60_000).toISOString();
    const ex = await svc.from("exams").insert({
      subject_id: subjectId,
      title: "ZZ Fn exam",
      paper: "Paper 1",
      format: "online",
      starts_at: starts,
      duration_minutes: 90,
      price_pence: 0,
      price_confirmed: true,
      booking_deadline: starts,
      status: "published",
      exam_code: fx.examCode,
    }).select("id").single();
    if (ex.error) throw new Error(`exam: ${ex.error.message}`);
    examId = ex.data.id as string;
    const bk = await svc.from("bookings").insert({
      exam_id: examId,
      student_id: fx.student.id,
      booked_by: fx.student.id,
      status: "paid",
      amount_pence: 0,
      sitting: "home",
    }).select("id").single();
    if (bk.error) throw new Error(`booking: ${bk.error.message}`);

    fx.svc = svc;
    fx.examId = examId;
    fx.bookingId = bk.data.id as string;
    fx.upload = async (bytes) => {
      const path = `${examId}/${crypto.randomUUID()}.pdf`;
      const up = await svc.storage.from(BUCKET).upload(path, bytes, { contentType: "application/pdf" });
      if (up.error) throw new Error(`upload: ${up.error.message}`);
      paths.push(path);
      return path;
    };
    fx.addPaper = async (bytes, kind, pages, title) => {
      const path = await fx.upload(bytes);
      const row = await svc.from("exam_papers").insert({
        exam_id: examId,
        kind,
        title: title ?? (kind === "paper" ? "Question paper" : "Formula sheet"),
        version: 1,
        storage_path: path,
        page_count: pages,
        byte_size: bytes.length,
      }).select("id").single();
      if (row.error) throw new Error(`paper: ${row.error.message}`);
      return { id: row.data.id as string, path };
    };
    fx.cleanup = async () => {
      const failures: string[] = [];
      const check = (step: string, r: { error: { message: string } | null }) => {
        if (r.error) failures.push(`${step}: ${r.error.message}`);
      };
      try {
        const copies = await svc.from("paper_copies").select("id").eq("booking_id", fx.bookingId);
        const ids = (copies.data ?? []).map((c) => c.id as string);
        if (ids.length) check("downloads", await svc.from("paper_downloads").delete().in("copy_id", ids));
        check("copies", await svc.from("paper_copies").delete().eq("booking_id", fx.bookingId));
        const papers = await svc.from("exam_papers").select("id, storage_path").eq("exam_id", examId!);
        for (const p of papers.data ?? []) paths.push(p.storage_path as string);
        check("papers", await svc.from("exam_papers").delete().eq("exam_id", examId!));
        check("bookings", await svc.from("bookings").delete().eq("exam_id", examId!));
        check("exam", await svc.from("exams").delete().eq("id", examId!));
        if (subjectId !== null) check("subject", await svc.from("subjects").delete().eq("id", subjectId));
        if (paths.length) check("objects", await svc.storage.from(BUCKET).remove(paths));
      } finally {
        await deleteUsers(svc, users);
        if (failures.length) throw new Error(`fixture cleanup failed: ${failures.join("; ")}`);
      }
    };
    return fx;
  } catch (err) {
    if (examId) await svc.from("bookings").delete().eq("exam_id", examId);
    if (examId) await svc.from("exams").delete().eq("id", examId);
    if (subjectId !== null) await svc.from("subjects").delete().eq("id", subjectId);
    if (paths.length) await svc.storage.from(BUCKET).remove(paths);
    await deleteUsers(svc, users);
    throw err;
  }
}
