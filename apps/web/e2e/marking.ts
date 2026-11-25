// Test-only helpers for the marking browser tests (marking.spec.ts, marking-admin.spec.ts). They run in the Playwright
// (Node) process with the service key from the env file, against the local stack only (e2e-local.mjs points
// E2E_ENV_FILE at it), and write the rows Phase 2 leaves behind for a verified home script directly, as
// supabase/tests/helpers.sql does, with real JPEG pictures in script-pages. For the marking screen, marking is opened by
// the admin through marking_open; for the staff test, the admin does everything in the browser. Everything they make
// is removed by removeMarkingExam (with the accounts, by cleanup in admin.ts).
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { chromium, type Page } from "@playwright/test";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { ANON_KEY, SUPABASE_URL, createAccount, svc, type TestAccount } from "./admin";
import { CODE_A, CODE_B, removeExam, seedExam, type SeededExam } from "./scripts";

export type Login = TestAccount;
export type SeededStudent = { firstName: string; lastName: string; indexNumber: string };
/** A seeded candidate with their verified script. */
export type SeededScript = SeededStudent & { scriptId: string; scriptNumber: string };
/** A page's pictures as stored in script-pages: the marking picture, and the full picture when a test needs one. */
type PagePictures = { full?: Buffer; marking: Buffer };

const host = new URL(SUPABASE_URL).hostname;
if (host !== "127.0.0.1" && host !== "localhost") throw new Error(`the marking helpers run against the local stack only, not ${host}`);

const must = <T>(r: { data: T; error: { message: string } | null }, what: string): NonNullable<T> => {
  if (r.error || r.data === null || r.data === undefined) throw new Error(`${what} failed: ${r.error?.message ?? "no row"}`);
  return r.data as NonNullable<T>;
};

// Names no screen of the marker may show: page.content() is searched for each.
const FIRST = ["Wilhelmina", "Bartholomew", "Octavia", "Peregrine", "Cordelia"];
const LAST = ["Quarterfield", "Ashbourne", "Fenwicke", "Holloway", "Marchbank"];
/** The structure: three questions, each on its own answer page of the 3-page paper. Question 3 is out of 15, so its
 * mark has buttons and the number box a digit key goes to. */
export const QUESTIONS = [
  { label: "1", max: 5, page: 1 },
  { label: "2", max: 4, page: 2 },
  { label: "3", max: 15, page: 3 },
] as const;

const seeded = new Map<string, SeededExam>();

/**
 * The three answer pages as JPEG pictures (827 x 1170, half the size the processor makes), drawn once in a headless
 * browser and kept in the temp folder. They carry no name: a marking picture never does.
 */
async function markingPictures(): Promise<Buffer[]> {
  const dir = join(tmpdir(), "stem-e2e-marking", "pictures-v2");
  const files = QUESTIONS.map((q) => join(dir, `page-${q.page}.jpg`));
  if (files.every((f) => existsSync(f))) return files.map((f) => readFileSync(f));
  mkdirSync(dir, { recursive: true });
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage({ viewport: { width: 827, height: 1170 } });
    for (const [i, q] of QUESTIONS.entries()) {
      const lines = Array.from({ length: 24 }, () => `<div style="height:40px;border-bottom:1px solid #c9d3e0"></div>`).join("");
      await page.setContent(
        `<body style="margin:0;background:#fff;font-family:Arial,sans-serif">
          <div style="padding:60px 70px">
            <div style="font:600 22px Arial;color:#222">Answer page ${q.page}</div>
            <div style="font:16px Arial;color:#444;margin:12px 0 24px">Question ${q.label} [${q.max} marks]</div>
            <div style="position:relative">${lines}
              <div style="position:absolute;top:8px;left:10px;font:italic 26px Arial,sans-serif;color:#1d3c8f">
                v = d / t = 120 / 1.5 = 80 km/h</div>
            </div>
          </div></body>`,
      );
      const jpeg = await page.screenshot({ type: "jpeg", quality: 75 });
      writeFileSync(files[i], jpeg);
    }
  } finally {
    await browser.close();
  }
  return files.map((f) => readFileSync(f));
}

/**
 * Candidate i + 1 of a seeded exam (a new active student named FIRST[i] LAST[i], index number E2EM-{tag}-{i + 1}) with
 * a verified home script S-{exam code}-{i + 1}: a paid booking, a copy with this code, a received hand-in whose PDF was
 * processed, the 3 matched pages with their pictures in script-pages (page n gets pictures[n - 1]), and version 1
 * linking them. Handed in 15 minutes after the finish.
 */
async function seedScript(exam: SeededExam, i: number, tag: string, code: string, pictures: PagePictures[]): Promise<SeededScript> {
  const examRow = must(await svc().from("exams").select("starts_at, duration_minutes, spare_pages, price_pence").eq("id", exam.examId).single(), "exam read");
  const handedIn = new Date(Date.parse(examRow.starts_at) + (examRow.duration_minutes + 15) * 60_000).toISOString();
  const indexNumber = `E2EM-${tag.toUpperCase()}-${i + 1}`;
  const scriptNumber = `S-${exam.examCode}-${String(i + 1).padStart(4, "0")}`;
  const student = await createAccount({ status: "active", firstName: FIRST[i], indexNumber });
  must(await svc().from("profiles").update({ first_name: FIRST[i], last_name: LAST[i] }).eq("id", student.id).select("id").single(), "name update");
  const booking = must(
    await svc().from("bookings").insert({ exam_id: exam.examId, student_id: student.id, booked_by: student.id, status: "paid", amount_pence: examRow.price_pence, sitting: "home" }).select("id").single(),
    "booking insert",
  );
  const copy = must(
    await svc().from("paper_copies").insert({ code, booking_id: booking.id, paper_id: exam.paperId, page_count: 3 + examRow.spare_pages, created_at: examRow.starts_at }).select("id").single(),
    "copy insert",
  );
  const submission = must(
    await svc().from("home_submissions").insert({ booking_id: booking.id, seq: 1, state: "received", submitted_by: student.id, submitted_at: handedIn, checked_at: handedIn }).select("id").single(),
    "submission insert",
  );
  const uploadId = crypto.randomUUID();
  must(
    await svc()
      .from("script_uploads")
      .insert({
        id: uploadId, exam_id: exam.examId, booking_id: booking.id, submission_id: submission.id, kind: "home_pdf", position: 1,
        storage_path: `home/${booking.id}/${uploadId}.pdf`, mime: "application/pdf", byte_size: 100000, sha256: uploadId.replace(/-/g, "").padEnd(64, "0"),
        state: "processed", uploaded_by: student.id, created_at: handedIn, stored_at: handedIn,
      })
      .select("id")
      .single(),
    "upload insert",
  );
  const dir = `${exam.examId}/${uploadId}/1-1`;
  const pages = must(
    await svc()
      .from("script_pages")
      .insert(QUESTIONS.map((q, n) => ({
        upload_id: uploadId, source_index: n, exam_id: exam.examId, copy_id: copy.id, copy_page: q.page, booking_id: booking.id, state: "matched",
        quality: { sharpness: 200, brightness: 180, cut_off: false, flags: [] }, rotation: 0,
        full_path: `${dir}/${n}-full.jpg`, marking_path: `${dir}/${n}-marking.jpg`, created_at: handedIn,
      })))
      .select("id, copy_page, full_path, marking_path"),
    "pages insert",
  );
  for (const p of pages) {
    const picture = pictures[(p.copy_page as number) - 1];
    const files: [string, Buffer | undefined][] = [[p.full_path as string, picture.full], [p.marking_path as string, picture.marking]];
    for (const [path, bytes] of files) {
      if (!bytes) continue;
      const up = await svc().storage.from("script-pages").upload(path, bytes, { contentType: "image/jpeg", upsert: false });
      if (up.error) throw new Error(`picture upload failed: ${up.error.message}`);
    }
  }
  const script = must(
    await svc()
      .from("scripts")
      .insert({ booking_id: booking.id, exam_id: exam.examId, source: "home", number: scriptNumber, state: "verified", version: 1, complete: true, received_at: handedIn, created_at: handedIn })
      .select("id")
      .single(),
    "script insert",
  );
  must(await svc().from("script_versions").insert({ script_id: script.id, version: 1, created_at: handedIn, reason: "home_submission", submission_id: submission.id }).select("script_id").single(), "version insert");
  must(await svc().from("script_page_links").insert(pages.map((p) => ({ script_id: script.id, version: 1, copy_page: p.copy_page, page_id: p.id }))).select("page_id"), "links insert");
  return { firstName: FIRST[i], lastName: LAST[i], indexNumber, scriptId: script.id, scriptNumber };
}

/** The checks on an exam's marking (exam_marking): what is not given is off, with the database's own defaults for the
 * sample (10%) and the gap between seeds (10). */
export type Checks = { double_marking?: boolean; sample_percent?: number; seeds?: boolean; seed_every?: number; practice?: boolean };

/**
 * An exam marked as whole scripts (or by question: question 1 and 2 in "Section A", 3 in "Section B") with the
 * structure above, an approved corrector, an admin, and `scripts` verified home scripts of new active students with
 * names and index numbers, each with its 3 matched pages and their marking pictures. The exam finished 3 days ago, so
 * the hand-in time is over; the admin opens marking, which makes every script ready to mark. `markers` (1 by default)
 * approved correctors are made: `marker` is the first, `markers` all of them. Double marking, seeds and practice are
 * off (written with the service key, as tests.marking_exam does in supabase/tests/helpers.sql).
 */
export async function seedMarkingExam(opts: { scripts: number; mode?: "whole" | "by_question"; markers?: number }): Promise<{
  examId: string;
  title: string;
  marker: Login;
  markers: Login[];
  admin: Login;
  students: SeededStudent[];
}> {
  const s = await seedMarking({ scripts: opts.scripts, mode: opts.mode ?? "whole", markers: opts.markers ?? 1, checks: {}, lead: false });
  return { examId: s.examId, title: s.title, marker: s.markers[0], markers: s.markers, admin: s.admin, students: s.students };
}

/** seedMarkingExam, with the checks given and, with `lead`, an approved lead marker of the subject (`Lead`). With
 * `open: false` (3B Task 13) marking is left for the admin to open in the browser. */
async function seedMarking(opts: { scripts: number; mode: "whole" | "by_question"; markers: number; checks: Checks; lead: boolean; open?: boolean }): Promise<{
  examId: string;
  title: string;
  subject: string;
  markers: Login[];
  lead: Login | null;
  admin: Login;
  students: SeededStudent[];
}> {
  if (opts.scripts < 1 || opts.scripts > FIRST.length) throw new Error(`seedMarkingExam makes 1 to ${FIRST.length} scripts`);
  const mode = opts.mode;
  const tag = crypto.randomUUID().slice(0, 8);
  const pictures = await markingPictures();
  const admin = await createAccount({ role: "admin" });
  const markers: Login[] = [];
  for (let i = 0; i < opts.markers; i++) markers.push(await createAccount({ role: "corrector", firstName: i === 0 ? "Marker" : `Marker${i + 1}` }));
  const lead = opts.lead ? await createAccount({ role: "corrector", firstName: "Lead" }) : null;
  const exam = await seedExam({ tag, title: "Marking", sitting: "home", startedMinutesAgo: 3 * 24 * 60, adminId: admin.id });
  seeded.set(exam.examId, exam);
  for (const m of markers) {
    must(await svc().from("marker_approvals").insert({ marker_id: m.id, subject_id: exam.subjectId, approved_by: admin.id, approved_at: new Date().toISOString() }).select("marker_id").single(), "approval insert");
  }
  if (lead) {
    must(
      await svc().from("marker_approvals").insert({ marker_id: lead.id, subject_id: exam.subjectId, lead: true, approved_by: admin.id, approved_at: new Date().toISOString() }).select("marker_id").single(),
      "lead approval insert",
    );
  }

  // The structure, entered directly (exam_structure_save needs an editor's session).
  const groups: Record<string, string> = {};
  if (mode === "by_question") {
    for (const [position, label] of ["Section A", "Section B"].entries()) {
      groups[label] = must(await svc().from("question_groups").insert({ exam_id: exam.examId, label, position: position + 1 }).select("id").single(), "group insert").id;
    }
  }
  for (const [i, q] of QUESTIONS.entries()) {
    const row = must(
      await svc()
        .from("exam_questions")
        .insert({
          exam_id: exam.examId,
          label: q.label,
          position: i + 1,
          max_mark: q.max,
          pages: [q.page],
          guidance: `Question ${q.label}: credit any correct method.`,
          group_id: mode === "by_question" ? groups[i < 2 ? "Section A" : "Section B"] : null,
        })
        .select("id")
        .single(),
      "question insert",
    );
    must(
      await svc().from("mark_scheme_points").insert([
        { question_id: row.id, position: 1, label: "M1", marks: 1, text: "A correct method." },
        { question_id: row.id, position: 2, label: "A1", marks: q.max - 1, text: "The correct answer with units." },
      ]).select("id"),
      "marking points insert",
    );
  }

  const students: SeededStudent[] = [];
  for (let i = 0; i < opts.scripts; i++) {
    const code = must(await svc().rpc("copy_code_new"), "copy code");
    const { firstName, lastName, indexNumber } = await seedScript(exam, i, tag, code, pictures.map((marking) => ({ marking })));
    students.push({ firstName, lastName, indexNumber });
  }

  // The checks on the marking: with all of them off, one approved marker and no lead marker may open it.
  const c = opts.checks;
  must(
    await svc()
      .from("exam_marking")
      .insert({
        exam_id: exam.examId,
        double_marking: c.double_marking ?? false,
        sample_percent: c.sample_percent ?? 10,
        seeds: c.seeds ?? false,
        seed_every: c.seed_every ?? 10,
        practice: c.practice ?? false,
      })
      .select("exam_id")
      .single(),
    "checks insert",
  );

  // The admin opens marking, as on the exam's marking panel.
  if (opts.open !== false) {
    await asUser(admin, async (client) => {
      const settings = await client.rpc("marking_settings_set", { p_exam: exam.examId, p_mode: mode, p_deadline: null });
      if (settings.error || settings.data?.ok !== true) throw new Error(`marking settings failed: ${settings.error?.message ?? JSON.stringify(settings.data)}`);
      const opened = await client.rpc("marking_open", { p_exam: exam.examId });
      if (opened.error || opened.data?.ok !== true || opened.data?.ready !== opts.scripts) {
        throw new Error(`marking open failed: ${opened.error?.message ?? JSON.stringify(opened.data)}`);
      }
    });
  }
  const subject = must(await svc().from("subjects").select("name").eq("id", exam.subjectId).single(), "subject read").name as string;
  return { examId: exam.examId, title: exam.title, subject, markers, lead, admin, students };
}

/**
 * For the staff browser test of the checks (3B Task 13): an exam marked as whole scripts with the structure above, an
 * admin, two approved correctors (`markers`: "Marker Tester" and "Marker2 Tester"), an approved lead marker ("Lead
 * Tester") and `scripts` verified home scripts of candidates with names and index numbers. Its checks are written as
 * given (double marking, seeded scripts; practice off, so the markers need no clearing), and marking is left for the
 * admin to open: the exam's pieces are made when it opens (unitsOf).
 */
export async function seedChecksExam(opts: { scripts: number; checks: Checks }): Promise<{
  examId: string;
  title: string;
  subject: string;
  admin: Login;
  markers: Login[];
  lead: Login;
  students: SeededStudent[];
}> {
  const s = await seedMarking({ scripts: opts.scripts, mode: "whole", markers: 2, checks: opts.checks, lead: true, open: false });
  return { examId: s.examId, title: s.title, subject: s.subject, admin: s.admin, markers: s.markers, lead: s.lead!, students: s.students };
}

/** An exam's pieces in script order, with their script numbers. */
export async function unitsOf(examId: string): Promise<{ unitId: string; scriptNumber: string }[]> {
  const rows = must(await svc().from("marking_units").select("id, scripts(number)").eq("exam_id", examId), "units read") as unknown as { id: string; scripts: { number: string } }[];
  return rows.sort((a, b) => a.scripts.number.localeCompare(b.scripts.number)).map((r) => ({ unitId: r.id, scriptNumber: r.scripts.number }));
}

/** The admin assigns pieces to a marker as a first (live) or second pass (marking_assign, as "Assign to…"). */
export async function assignAs(admin: Login, unitIds: string[], marker: Login, kind: "live" | "second" = "live"): Promise<void> {
  const r = await rpcAs(admin, "marking_assign", { p_units: unitIds, p_marker: marker.id, p_reason: "Handed out for the test", p_kind: kind });
  if (r.assigned !== unitIds.length) throw new Error(`marking_assign skipped pieces: ${JSON.stringify(r)}`);
}

/** The lead takes a routine sample of a marker's work on the exam (marking_review_sample); how many were added. */
export async function sampleAs(lead: Login, examId: string, markerId: string, count = 5): Promise<number> {
  return Number((await rpcAs(lead, "marking_review_sample", { p_exam: examId, p_marker: markerId, p_count: count })).added);
}

/** The lead sends a piece back to the same marker with a note (marking_send_back, as "Send back" on the review screen). */
export async function sendBackAs(lead: Login, unitId: string, note: string): Promise<void> {
  await rpcAs(lead, "marking_send_back", { p_unit: unitId, p_to: "same", p_note: note, p_reason: "Question 3 looks too generous" });
}

/** The lead settles the open difference on a piece at its markings' current revs (marking_review_settle). */
export async function settleAs(lead: Login, unitId: string, outcome: "first_stands" | "second_stands"): Promise<string> {
  const review = must(await svc().from("marking_reviews").select("id").eq("unit_id", unitId).eq("kind", "difference").eq("state", "open").single(), "review read");
  const rev = async (kind: string) =>
    must(await svc().from("markings").select("rev").eq("unit_id", unitId).eq("kind", kind).eq("status", "submitted").single(), `${kind} marking read`).rev as number;
  await rpcAs(lead, "marking_review_settle", {
    p_review: review.id,
    p_outcome: outcome,
    p_first_rev: await rev("live"),
    p_second_rev: await rev("second"),
    p_reason: "The second marks are right",
  });
  return review.id as string;
}

/** The marker's next Next script on the exam gives a seeded script (exam_markers.until_seed 0, made if it is not there). */
export async function seedNext(examId: string, markerId: string): Promise<void> {
  must(await svc().from("exam_markers").upsert({ exam_id: examId, marker_id: markerId, until_seed: 0 }, { onConflict: "exam_id,marker_id" }).select("exam_id").single(), "until_seed upsert");
}

/** A change to a submitted piece, as `who`'s screen would send it, with a reason: the code it is refused with ("ok"
 * when it is saved). */
export async function changeAs(who: Login, unitId: string, marks: number[]): Promise<string> {
  return asUser(who, async (client) => {
    const opened = await client.rpc("marking_unit_open", { p_unit: unitId });
    const o = opened.data as { ok?: boolean; code?: string; marking: { id: string; rev: number }; structure: { questions: { id: string; parent_id: string | null }[] } } | null;
    if (opened.error || !o) throw new Error(`marking_unit_open failed: ${opened.error?.message ?? "no answer"}`);
    if (o.ok !== true) return o.code ?? "none";
    const parents = new Set(o.structure.questions.flatMap((q) => (q.parent_id ? [q.parent_id] : [])));
    const ops = o.structure.questions.filter((q) => !parents.has(q.id)).map((q, i) => ({ op: "mark", question_id: q.id, mark: marks[i], na: false }));
    const saved = await client.rpc("marking_save", { p_marking: o.marking.id, p_rev: o.marking.rev, p_ops: ops, p_reason: "A slip in question 1" });
    if (saved.error) throw new Error(`marking_save failed: ${saved.error.message}`);
    return saved.data?.ok === true ? "ok" : String(saved.data?.code ?? "none");
  });
}

/** The admin withdraws the exam's approval when it is approved (before its rows are removed); otherwise nothing. */
export async function withdrawApprovalIfAny(admin: Login, examId: string): Promise<void> {
  const m = (await svc().from("exam_marking").select("approved_at").eq("exam_id", examId).maybeSingle()).data;
  if (m?.approved_at) await rpcAs(admin, "marking_approval_withdraw", { p_exam: examId, p_reason: "The test is over" });
}

/** Runs `fn` with a client signed in as `who` (the anon key and their own session, as their browser would), then
 * signs out. */
async function asUser<T>(who: Login, fn: (client: SupabaseClient) => Promise<T>): Promise<T> {
  const client = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const signIn = await client.auth.signInWithPassword({ email: who.email, password: who.password });
  if (signIn.error) throw new Error(`sign-in failed: ${signIn.error.message}`);
  try {
    return await fn(client);
  } finally {
    await client.auth.signOut();
  }
}

/** Calls one function as `who`; throws unless it answers {ok: true}. */
async function rpcAs(who: Login, fn: string, args: Record<string, unknown>): Promise<Record<string, unknown>> {
  return asUser(who, async (client) => {
    const r = await client.rpc(fn, args);
    if (r.error || r.data?.ok !== true) throw new Error(`${fn} failed: ${r.error?.message ?? JSON.stringify(r.data)}`);
    return r.data as Record<string, unknown>;
  });
}

/** The lead marker's marks for each question (1, 2, 3) of the pieces they use for practice or as seeded scripts. */
export const LEAD_MARKS = [3, 2, 10] as const;
/** The lead marker's note on each of those pieces. */
export const STANDARD_NOTE = "Question 3 needs the units for the last mark.";

/**
 * An exam (whole scripts) with checks on the marking: as seedMarkingExam, with the checks given, `markers` approved
 * correctors (1 by default) and an approved lead marker of the subject. Once marking is open, the lead marks pieces
 * themselves (the admin assigns them, in script order, and the lead marks them through the functions with
 * LEAD_MARKS) and uses them: 2 for practice when practice is on, then 2 as seeded scripts when seeds are on, each
 * with STANDARD_NOTE. The other scripts are left for live marking; standardsOf says which pieces are which.
 */
export async function seedCheckedExam(opts: { scripts: number; checks: Checks; markers?: number }): Promise<{
  examId: string;
  lead: Login;
  markers: Login[];
  admin: Login;
  students: SeededStudent[];
}> {
  const uses = [...(opts.checks.practice ? ["practice", "practice"] : []), ...(opts.checks.seeds ? ["seed", "seed"] : [])];
  if (uses.length >= opts.scripts) throw new Error(`seedCheckedExam needs more than ${uses.length} scripts, to leave some for live marking`);
  const s = await seedMarking({ scripts: opts.scripts, mode: "whole", markers: opts.markers ?? 1, checks: opts.checks, lead: true });
  const lead = s.lead!;
  if (uses.length > 0) {
    const units = await unitsInOrder(s.examId);
    const theirs = units.slice(0, uses.length);
    const assigned = await rpcAs(s.admin, "marking_assign", { p_units: theirs, p_marker: lead.id, p_reason: "The lead marks these first", p_kind: "live" });
    if (assigned.assigned !== theirs.length) throw new Error(`marking_assign skipped pieces: ${JSON.stringify(assigned)}`);
    for (const [i, unitId] of theirs.entries()) {
      await markAs(lead, unitId, [...LEAD_MARKS]);
      await rpcAs(lead, "marking_standard_set", { p_unit: unitId, p_use: uses[i], p_note: STANDARD_NOTE });
    }
  }
  return { examId: s.examId, lead, markers: s.markers, admin: s.admin, students: s.students };
}

/** An exam's pieces in script order. */
async function unitsInOrder(examId: string): Promise<string[]> {
  const rows = must(await svc().from("marking_units").select("id, scripts(number)").eq("exam_id", examId), "units read") as unknown as { id: string; scripts: { number: string } }[];
  return rows.sort((a, b) => a.scripts.number.localeCompare(b.scripts.number)).map((r) => r.id);
}

/**
 * Marks a piece as `login`, through the functions with their own session, as their marking screen would: opens it
 * (they must hold it: Next script, or an admin's assignment), gives each question its mark in paper order (`marks`:
 * one per question), with `tick` a tick on its first page and with `note` a note to the lead marker, and submits.
 */
export async function markAs(login: Login, unitId: string, marks: number[], opts: { tick?: boolean; note?: string } = {}): Promise<void> {
  await asUser(login, async (client) => {
    const opened = await client.rpc("marking_unit_open", { p_unit: unitId });
    const o = opened.data as { ok?: boolean; marking: { id: string; rev: number }; structure: { questions: { id: string; parent_id: string | null }[] }; pages: { page_id: string }[] } | null;
    if (opened.error || o?.ok !== true) throw new Error(`marking_unit_open failed: ${opened.error?.message ?? JSON.stringify(o)}`);
    const parents = new Set(o.structure.questions.flatMap((q) => (q.parent_id ? [q.parent_id] : [])));
    const leaves = o.structure.questions.filter((q) => !parents.has(q.id));
    if (leaves.length !== marks.length) throw new Error(`markAs needs ${leaves.length} marks, not ${marks.length}`);
    const ops: Record<string, unknown>[] = leaves.map((q, i) => ({ op: "mark", question_id: q.id, mark: marks[i], na: false }));
    if (opts.tick) ops.push({ op: "ann_put", id: crypto.randomUUID(), page_id: o.pages[0].page_id, kind: "tick", x: 0.3, y: 0.2, question_id: leaves[0].id });
    if (opts.note) ops.push({ op: "note", text: opts.note });
    const saved = await client.rpc("marking_save", { p_marking: o.marking.id, p_rev: o.marking.rev, p_ops: ops });
    if (saved.error || saved.data?.ok !== true) throw new Error(`marking_save failed: ${saved.error?.message ?? JSON.stringify(saved.data)}`);
    const submitted = await client.rpc("marking_submit", { p_marking: o.marking.id, p_rev: saved.data.rev });
    if (submitted.error || submitted.data?.ok !== true) throw new Error(`marking_submit failed: ${submitted.error?.message ?? JSON.stringify(submitted.data)}`);
  });
}

/** Next script as `login`, through the function: the piece it hands them. */
export async function nextAs(login: Login, examId: string): Promise<string> {
  const r = await rpcAs(login, "marking_next", { p_exam: examId });
  return r.unit_id as string;
}

/** The lead clears a marker for live marking on the exam (marking_marker_clear), with a reason. */
export async function clearMarker(lead: Login, examId: string, markerId: string): Promise<void> {
  await rpcAs(lead, "marking_marker_clear", { p_exam: examId, p_marker: markerId, p_reason: "Practice scripts looked at" });
}

/** The lead pauses a marker on the exam (marking_marker_pause, applied at once), with a reason. */
export async function pauseMarker(lead: Login, examId: string, markerId: string): Promise<void> {
  await rpcAs(lead, "marking_marker_pause", { p_exam: examId, p_marker: markerId, p_reason: "Marks to look at together" });
}

/** Sets a marker's count to their next seeded script on the exam (exam_markers.until_seed; their first Next script on
 * the exam made the row). 0: the next Next script gives a seed. */
export async function setUntilSeed(examId: string, markerId: string, n: number): Promise<void> {
  must(await svc().from("exam_markers").update({ until_seed: n }).eq("exam_id", examId).eq("marker_id", markerId).select("exam_id").single(), "until_seed update");
}

/** The pieces the lead uses for practice or as seeded scripts on the exam. */
export async function standardsOf(examId: string): Promise<{ unitId: string; use: "practice" | "seed" }[]> {
  const rows = must(await svc().from("marking_standards").select("unit_id, use").eq("exam_id", examId), "standards read");
  return rows.map((r) => ({ unitId: r.unit_id as string, use: r.use as "practice" | "seed" }));
}

/** A piece's check state (waiting_second, to_lead, checked, or null). */
export async function checkStateOf(unitId: string): Promise<string | null> {
  return must(await svc().from("marking_units").select("check_state").eq("id", unitId).single(), "unit read").check_state as string | null;
}

/** A piece's open holds of every kind: who holds it, as what, and for how long (ms), in the order they were made. */
export async function holdsOn(unitId: string): Promise<{ marker: string; kind: string; how: string; ms: number | null }[]> {
  const rows = must(await svc().from("marking_assignments").select("marker_id, kind, how, created_at, hold_until").eq("unit_id", unitId).is("ended_at", null).order("created_at"), "holds read");
  return rows.map((a) => ({
    marker: a.marker_id as string,
    kind: a.kind as string,
    how: a.how as string,
    ms: a.hold_until ? Date.parse(a.hold_until as string) - Date.parse(a.created_at as string) : null,
  }));
}

/** The admin takes pieces back from their markers (marking_take_back, as "Take back" on the admin marking page). */
export async function takeBackPieces(admin: Login, unitIds: string[], reason: string): Promise<void> {
  const client = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const signIn = await client.auth.signInWithPassword({ email: admin.email, password: admin.password });
  if (signIn.error) throw new Error(`admin sign-in failed: ${signIn.error.message}`);
  try {
    const r = await client.rpc("marking_take_back", { p_units: unitIds, p_reason: reason });
    if (r.error || r.data?.ok !== true) throw new Error(`take back failed: ${r.error?.message ?? JSON.stringify(r.data)}`);
  } finally {
    await client.auth.signOut();
  }
}

/** supabase-js as one browser script (window.supabase), for a test to act in a page with the user's own session. */
export const SUPABASE_BROWSER_SCRIPT = join(dirname(require.resolve("@supabase/supabase-js")), "umd", "supabase.js");

/** A piece's pages with their pictures' paths, in copy page order (the service key reads them; no marker ever does). */
export async function piecePictures(unitId: string): Promise<{ pageId: string; copyPage: number; markingPath: string; fullPath: string }[]> {
  const u = must(await svc().from("marking_units").select("script_id").eq("id", unitId).single(), "unit read");
  const links = must(await svc().from("script_page_links").select("page_id, copy_page").eq("script_id", u.script_id), "links read");
  const pages = must(await svc().from("script_pages").select("id, marking_path, full_path").in("id", links.map((l) => l.page_id)), "pages read");
  return links
    .map((l) => {
      const p = pages.find((x) => x.id === l.page_id)!;
      return { pageId: l.page_id as string, copyPage: l.copy_page as number, markingPath: p.marking_path as string, fullPath: p.full_path as string };
    })
    .sort((a, b) => a.copyPage - b.copyPage);
}

/** A new corrector, approved for the exam's subject as its lead marker. */
export async function makeLead(examId: string): Promise<Login> {
  const exam = seeded.get(examId);
  if (!exam) throw new Error("not a seeded exam");
  const lead = await createAccount({ role: "corrector", firstName: "Lead" });
  must(
    await svc().from("marker_approvals").insert({ marker_id: lead.id, subject_id: exam.subjectId, lead: true, approved_at: new Date().toISOString() }).select("marker_id").single(),
    "lead approval insert",
  );
  return lead;
}

/**
 * A page's marking picture made again to hide something else, as a remask after a change of hidden areas records it:
 * the inputs its picture was made from are marked as different, and a new picture (the old one's bytes) is stored at a
 * new path and recorded. The database then holds the script's pieces and raises a picture_changed alert. Returns the
 * new path.
 */
export async function changePicture(pageId: string): Promise<string> {
  const p = must(await svc().from("script_pages").select("marking_path").eq("id", pageId).single(), "page read");
  const old = p.marking_path as string;
  const bytes = must(await svc().storage.from("script-pages").download(old), "picture download");
  const next = old.replace(/-marking\.jpg$/, "-remask-marking.jpg");
  const up = await svc().storage.from("script-pages").upload(next, Buffer.from(await bytes.arrayBuffer()), { contentType: "image/jpeg", upsert: true });
  if (up.error) throw new Error(`picture upload failed: ${up.error.message}`);
  must(await svc().from("script_pages").update({ marking_inputs: "made before the change" }).eq("id", pageId).select("id").single(), "inputs update");
  must(await svc().from("script_pages").update({ marking_path: next }).eq("id", pageId).select("id").single(), "picture update");
  return next;
}

/** A piece's hold: "on_hold hold_reason", as the database holds it. */
export async function unitHold(unitId: string): Promise<string> {
  const u = must(await svc().from("marking_units").select("on_hold, hold_reason").eq("id", unitId).single(), "unit read");
  return `${u.on_hold} ${u.hold_reason}`;
}

/** Who holds each piece of an exam now (an open live assignment), by piece. */
export async function holdersOf(examId: string): Promise<{ unitId: string; holder: string }[]> {
  const units = ids((await svc().from("marking_units").select("id").eq("exam_id", examId)).data);
  if (units.length === 0) return [];
  const { data } = await svc().from("marking_assignments").select("unit_id, marker_id").in("unit_id", units).eq("kind", "live").is("ended_at", null);
  return (data ?? []).map((a) => ({ unitId: a.unit_id as string, holder: a.marker_id as string }));
}

const PROCESSOR = resolve(__dirname, "../../../services/processor");

/**
 * The full and marking pictures the processing server makes of pages 1 to 3 of the fixture copies A and B
 * (services/processor/tests/e2e_pages.py), so a remask proves them again as it proves a real scan. Made once inside
 * its container (it must be running: npm run e2e:local starts it) and kept in the temp folder under a hash of
 * everything that makes them.
 */
function fixturePictures(): Record<"a" | "b", Required<PagePictures>[]> {
  const hash = createHash("sha256");
  const inputs = [
    "tests/e2e_pages.py",
    "tests/e2e_files.py",
    "tests/synth.py",
    "tests/fixtures/copy-a.pdf",
    "tests/fixtures/copy-b.pdf",
    "tests/fixtures/codes.json",
    ...readdirSync(join(PROCESSOR, "processor")).filter((f) => f.endsWith(".py")).sort().map((f) => `processor/${f}`),
  ];
  for (const f of inputs) hash.update(f).update(readFileSync(join(PROCESSOR, f)));
  const dir = join(tmpdir(), "stem-e2e-marking", `pages-${hash.digest("hex").slice(0, 16)}`);
  const file = (key: string, n: number, kind: string) => join(dir, `${key}-${n}-${kind}.jpg`);
  const keys = ["a", "b"] as const;
  const all = keys.flatMap((k) => [1, 2, 3].flatMap((n) => [file(k, n, "full"), file(k, n, "marking")]));
  if (!all.every((f) => existsSync(f))) {
    const out = execFileSync("docker", ["compose", "-f", join(PROCESSOR, "docker-compose.yml"), "exec", "-T", "processor", "python", "tests/e2e_pages.py"], {
      encoding: "utf8",
      maxBuffer: 64 << 20,
    });
    const made = JSON.parse(out) as Record<string, { full: string; marking: string }[]>;
    mkdirSync(dir, { recursive: true });
    for (const k of keys) {
      made[k].forEach((p, i) => {
        writeFileSync(file(k, i + 1, "full"), Buffer.from(p.full, "base64"));
        writeFileSync(file(k, i + 1, "marking"), Buffer.from(p.marking, "base64"));
      });
    }
  }
  const read = (k: "a" | "b") => [1, 2, 3].map((n) => ({ full: readFileSync(file(k, n, "full")), marking: readFileSync(file(k, n, "marking")) }));
  return { a: read("a"), b: read("b") };
}

/**
 * For the staff browser test: an exam with no questions and no marking settings, an admin, an approved corrector (the
 * marker), a corrector not approved yet (`Lead{tag}`, who the admin makes lead marker), and two verified home scripts of
 * candidates with names and index numbers, on the fixture copies A and B, whose pages carry the processing server's
 * own full and marking pictures. The exam finished 3 days ago, so the hand-in time is over.
 */
export async function seedStaffMarkingExam(): Promise<{
  examId: string;
  title: string;
  paperId: string;
  subject: string;
  admin: Login;
  marker: Login & { name: string };
  lead: Login & { name: string };
  scripts: SeededScript[];
}> {
  const tag = crypto.randomUUID().slice(0, 8);
  const pictures = fixturePictures();
  for (const code of [CODE_A, CODE_B]) {
    const { count } = await svc().from("paper_copies").select("*", { count: "exact", head: true }).eq("code", code);
    if ((count ?? 0) > 0) throw new Error(`the fixture code ${code} is in use by other local data`);
  }
  const admin = await createAccount({ role: "admin" });
  const marker = { ...(await createAccount({ role: "corrector", firstName: `Marker${tag}` })), name: `Marker${tag} Tester` };
  const lead = { ...(await createAccount({ role: "corrector", firstName: `Lead${tag}` })), name: `Lead${tag} Tester` };
  const exam = await seedExam({ tag, title: "Staff marking", sitting: "home", startedMinutesAgo: 3 * 24 * 60, adminId: admin.id });
  seeded.set(exam.examId, exam);
  must(await svc().from("marker_approvals").insert({ marker_id: marker.id, subject_id: exam.subjectId, approved_by: admin.id, approved_at: new Date().toISOString() }).select("marker_id").single(), "approval insert");
  const subject = must(await svc().from("subjects").select("name").eq("id", exam.subjectId).single(), "subject read").name as string;
  const scripts = [await seedScript(exam, 0, tag, CODE_A, pictures.a), await seedScript(exam, 1, tag, CODE_B, pictures.b)];
  return { examId: exam.examId, title: exam.title, paperId: exam.paperId, subject, admin, marker, lead, scripts };
}

/**
 * The hidden areas of a paper version, set by the admin (set_paper_hidden_areas, as the page-roles panel saves them),
 * which queues a remask of every file with a page on a changed page. Returns how many remasks were queued.
 */
export async function setPaperHiddenAreas(admin: Login, paperId: string, areas: { page: number; x: number; y: number; w: number; h: number }[]): Promise<number> {
  const client = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const signIn = await client.auth.signInWithPassword({ email: admin.email, password: admin.password });
  if (signIn.error) throw new Error(`admin sign-in failed: ${signIn.error.message}`);
  try {
    const r = await client.rpc("set_paper_hidden_areas", { p_paper: paperId, p_areas: areas });
    if (r.error || r.data?.ok !== true) throw new Error(`hidden areas failed: ${r.error?.message ?? JSON.stringify(r.data)}`);
    return Number(r.data.remask_queued);
  } finally {
    await client.auth.signOut();
  }
}

/** The states of an exam's remask jobs, in job order. */
export async function remaskStates(examId: string): Promise<string[]> {
  const uploads = ((await svc().from("script_uploads").select("id").eq("exam_id", examId)).data ?? []).map((u) => u.id as string);
  if (uploads.length === 0) return [];
  const { data } = await svc().from("processing_jobs").select("state").in("upload_id", uploads).eq("kind", "remask").order("id");
  return (data ?? []).map((j) => j.state as string);
}

/** A script's piece (an exam marked as whole scripts has one per script): its state and hold, and who holds it how. */
export async function pieceState(scriptId: string): Promise<{ unitId: string; state: string; onHold: boolean; holdReason: string | null; holder: string | null; how: string | null }> {
  const u = must(await svc().from("marking_units").select("id, state, on_hold, hold_reason").eq("script_id", scriptId).single(), "unit read");
  const { data: a } = await svc().from("marking_assignments").select("marker_id, how").eq("unit_id", u.id).eq("kind", "live").is("ended_at", null).maybeSingle();
  return { unitId: u.id, state: u.state, onHold: u.on_hold, holdReason: u.hold_reason, holder: a?.marker_id ?? null, how: a?.how ?? null };
}

/** A piece's live marking as the database holds it (the service key reads it). */
export async function markingOf(unitId: string): Promise<{ id: string; rev: number; status: string; total: number | null } | null> {
  const { data } = await svc().from("markings").select("id, rev, status, total").eq("unit_id", unitId).eq("kind", "live").neq("status", "set_aside").maybeSingle();
  return data ? { id: data.id, rev: data.rev, status: data.status, total: data.total === null ? null : Number(data.total) } : null;
}

/** The kinds of a piece's annotations that are not deleted, in the order they were made. */
export async function annotationKinds(unitId: string): Promise<string[]> {
  const m = await markingOf(unitId);
  if (!m) return [];
  const { data } = await svc().from("page_annotations").select("kind, created_at").eq("marking_id", m.id).is("deleted_at", null).order("created_at");
  return (data ?? []).map((a) => a.kind as string);
}

/** A piece's marks by question label: a number, "NR", or nothing for a question with no mark. */
export async function marksOf(unitId: string): Promise<Record<string, number | "NR">> {
  const m = await markingOf(unitId);
  if (!m) return {};
  const { data } = await svc().from("question_marks").select("mark, not_attempted, exam_questions(label)").eq("marking_id", m.id);
  const out: Record<string, number | "NR"> = {};
  for (const r of (data ?? []) as unknown as { mark: number | null; not_attempted: boolean; exam_questions: { label: string } | null }[]) {
    if (r.exam_questions) out[r.exam_questions.label] = r.not_attempted ? "NR" : Number(r.mark);
  }
  return out;
}

/** Another screen saved: the marking's rev moves on, so the screen's next save names an old rev. */
export async function bumpRev(unitId: string): Promise<void> {
  const m = await markingOf(unitId);
  if (!m) throw new Error("no marking to bump");
  must(await svc().from("markings").update({ rev: m.rev + 1 }).eq("id", m.id).select("id").single(), "rev bump");
}

/** The script number and index number of a piece (what the marker may see). */
export async function pieceOf(unitId: string): Promise<{ scriptNumber: string; indexNumber: string }> {
  const u = must(await svc().from("marking_units").select("script_id").eq("id", unitId).single(), "unit read");
  const s = must(await svc().from("scripts").select("number, booking_id").eq("id", u.script_id).single(), "script read");
  const b = must(await svc().from("bookings").select("student_id").eq("id", s.booking_id).single(), "booking read");
  const d = must(await svc().from("student_details").select("index_number").eq("profile_id", b.student_id).single(), "index read");
  return { scriptNumber: s.number, indexNumber: d.index_number as string };
}

type PointerInit = { pointerId: number; pointerType: "pen" | "touch"; x: number; y: number; pressure: number; buttons: number };

/** Fires pointer events (bubbling, as a real pen or finger does) at points given as fractions of the element. */
async function firePointers(page: Page, selector: string, events: ({ type: "pointerdown" | "pointermove" | "pointerup" | "pointercancel" } & PointerInit)[]): Promise<void> {
  await page.evaluate(
    ({ selector, events }) => {
      const el = document.querySelector(selector);
      if (!el) throw new Error(`no element ${selector}`);
      // Where the element was when the gesture began: a finger moves over the screen, whatever the page does.
      const r = el.getBoundingClientRect();
      for (const e of events) {
        el.dispatchEvent(
          new PointerEvent(e.type, {
            bubbles: true,
            cancelable: true,
            composed: true,
            pointerId: e.pointerId,
            pointerType: e.pointerType,
            isPrimary: e.pointerId === 1,
            pressure: e.pressure,
            button: e.type === "pointermove" ? -1 : 0,
            buttons: e.buttons,
            clientX: r.left + e.x * r.width,
            clientY: r.top + e.y * r.height,
          }),
        );
      }
    },
    { selector, events },
  );
}

const down = (p: Omit<PointerInit, "pressure" | "buttons">, pressure: number) => ({ type: "pointerdown" as const, ...p, pressure, buttons: 1 });
const move = (p: Omit<PointerInit, "pressure" | "buttons">, pressure: number) => ({ type: "pointermove" as const, ...p, pressure, buttons: 1 });
const up = (p: Omit<PointerInit, "pressure" | "buttons">) => ({ type: "pointerup" as const, ...p, pressure: 0, buttons: 0 });
const cancel = (p: Omit<PointerInit, "pressure" | "buttons">) => ({ type: "pointercancel" as const, ...p, pressure: 0, buttons: 0 });

/**
 * A pen stroke (pointer 1, pressure 0.5) through `points`, fractions of the element. With `touchDuring`, a finger
 * (pointer 2) goes down, moves along those points and lifts half way through the stroke, as a resting palm does. With
 * `cancel`, the browser breaks the stroke off at its last point (pointercancel) instead of the pen lifting.
 */
export async function penStroke(
  page: Page,
  selector: string,
  points: [number, number][],
  opts: { touchDuring?: [number, number][]; cancel?: boolean } = {},
): Promise<void> {
  const pen = (p: [number, number]) => ({ pointerId: 1, pointerType: "pen" as const, x: p[0], y: p[1] });
  const finger = (p: [number, number]) => ({ pointerId: 2, pointerType: "touch" as const, x: p[0], y: p[1] });
  const half = Math.max(1, Math.floor(points.length / 2));
  const palm = opts.touchDuring ?? [];
  const events = [
    down(pen(points[0]), 0.5),
    ...points.slice(1, half).map((p) => move(pen(p), 0.5)),
    ...(palm.length ? [down(finger(palm[0]), 0.5), ...palm.slice(1).map((p) => move(finger(p), 0.5)), up(finger(palm[palm.length - 1]))] : []),
    ...points.slice(half).map((p) => move(pen(p), 0.5)),
    (opts.cancel ? cancel : up)(pen(points[points.length - 1])),
  ];
  await firePointers(page, selector, events);
}

/** One finger (pointer 1) dragged from `from` to `to` (fractions of the element) in ten steps. */
export async function touchDrag(page: Page, selector: string, from: [number, number], to: [number, number]): Promise<void> {
  const at = (t: number) => ({ pointerId: 1, pointerType: "touch" as const, x: from[0] + (to[0] - from[0]) * t, y: from[1] + (to[1] - from[1]) * t });
  await firePointers(page, selector, [down(at(0), 0.5), ...Array.from({ length: 10 }, (_, i) => move(at((i + 1) / 10), 0.5)), up(at(1))]);
}

/** Two fingers (pointers 1 and 2) about the element's middle, moving apart (scale above 1) or together. */
export async function pinch(page: Page, selector: string, scale: number): Promise<void> {
  const gap = (t: number) => 0.1 * (1 + (scale - 1) * t);
  const a = (t: number) => ({ pointerId: 1, pointerType: "touch" as const, x: 0.5 - gap(t), y: 0.5 });
  const b = (t: number) => ({ pointerId: 2, pointerType: "touch" as const, x: 0.5 + gap(t), y: 0.5 });
  const steps = Array.from({ length: 10 }, (_, i) => (i + 1) / 10);
  await firePointers(page, selector, [down(a(0), 0.5), down(b(0), 0.5), ...steps.flatMap((t) => [move(a(t), 0.5), move(b(t), 0.5)]), up(a(1)), up(b(1))]);
}

const ids = (rows: { id: string }[] | null) => (rows ?? []).map((r) => r.id);

/** Removes an exam made by seedExam and its marking: pieces, markings, marks, annotations, structure and approvals,
 * and what the checks on the marking made (3B): final marks and their history, the lead's reviews, practice and seeded
 * scripts, and the markers' rows on the exam. */
export async function removeMarkingExam(examId: string): Promise<void> {
  const exam = seeded.get(examId);
  if (!exam) return;
  const units = ids((await svc().from("marking_units").select("id").eq("exam_id", examId)).data);
  if (units.length) {
    // The practice and seeded scripts first (their marks go with them, on delete cascade), so nothing below retires one.
    await svc().from("marking_standards").delete().in("unit_id", units);
    // Only the database removes final marks, with a reason: a live or second marking that leaves submitted has its
    // piece checked again, which removes them (with history) and withdraws an open review.
    await svc()
      .from("markings")
      .update({ status: "set_aside", set_aside_at: new Date().toISOString(), set_aside_reason: "taken_back" })
      .in("unit_id", units)
      .in("kind", ["live", "second"])
      .eq("status", "submitted");
    const finals = await svc().from("final_marks").select("unit_id").in("unit_id", units);
    if (finals.error || (finals.data ?? []).length) throw new Error(`final marks were not removed: ${finals.error?.message ?? `${finals.data?.length} left`}`);
    await svc().from("final_mark_history").delete().in("unit_id", units);
    await svc().from("marking_reviews").delete().in("unit_id", units);
    // A checked piece names the marking its final marks came from.
    await svc().from("marking_units").update({ final_marking_id: null }).in("id", units);
  }
  await svc().from("exam_markers").delete().eq("exam_id", examId);
  const markings = units.length ? ids((await svc().from("markings").select("id").in("unit_id", units)).data) : [];
  if (markings.length) {
    await svc().from("page_annotations").delete().in("marking_id", markings);
    await svc().from("question_mark_history").delete().in("marking_id", markings);
    await svc().from("question_marks").delete().in("marking_id", markings);
  }
  if (units.length) {
    await svc().from("marking_assignments").delete().in("unit_id", units);
    await svc().from("marking_unit_exclusions").delete().in("unit_id", units);
  }
  // An alert's email notice stays (the service key may only read script_notices), and so does an alert it names.
  await svc().from("marking_alerts").delete().eq("exam_id", examId);
  if (markings.length) await svc().from("markings").delete().in("id", markings);
  if (units.length) await svc().from("marking_units").delete().in("id", units);
  const questions = ids((await svc().from("exam_questions").select("id").eq("exam_id", examId)).data);
  if (questions.length) await svc().from("mark_scheme_points").delete().in("question_id", questions);
  await svc().from("exam_questions").delete().eq("exam_id", examId);
  await svc().from("question_groups").delete().eq("exam_id", examId);
  await svc().from("exam_option_groups").delete().eq("exam_id", examId);
  await svc().from("exam_mark_scheme_files").delete().eq("exam_id", examId);
  await svc().from("exam_marking").delete().eq("exam_id", examId);
  await svc().from("marker_approvals").delete().eq("subject_id", exam.subjectId);
  await removeExam(exam);
  seeded.delete(examId);
}
