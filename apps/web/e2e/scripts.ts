// Test-only helpers for the Phase 2 browser tests (scripts-home, scripts-centre). They run in the Playwright (Node)
// process with the service key from the env file, against the local stack and the processing server that e2e-local.mjs
// starts (docker compose). Every row and file they make is removed by removeExam.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { expect, type Page } from "@playwright/test";
import { svc } from "./admin";

const ROOT = resolve(__dirname, "../../..");
const PROCESSOR = join(ROOT, "services/processor");
const COMPOSE = join(PROCESSOR, "docker-compose.yml");
const CODES = JSON.parse(readFileSync(join(PROCESSOR, "tests/fixtures/codes.json"), "utf8")) as { codeA: string; codeB: string };
/** The copy codes printed on the committed fixture copies (services/processor/tests/fixtures). */
export const CODE_A = CODES.codeA;
export const CODE_B = CODES.codeB;
export const FILE_NAMES = ["a-1.jpg", "a-2.jpg", "a-3.jpg", "a-4.jpg", "a-5.jpg", "b-2.jpg", "batch.pdf"] as const;

const docker = (args: string[]) => execFileSync("docker", ["compose", "-f", COMPOSE, ...args], { encoding: "utf8", maxBuffer: 64 << 20 });

/** Fails with a clear message when the processing server is not running (npm run e2e:local starts it). */
export function requireProcessor(): void {
  const running = docker(["ps", "--status", "running", "-q", "processor"]).trim();
  if (!running) throw new Error("The processing server is not running: use npm run e2e:local, or docker compose -f services/processor/docker-compose.yml up -d processor");
}

/**
 * The browser tests' upload files (see services/processor/tests/e2e_files.py): photos of copy A's pages 1-5 and of copy
 * B's page 2, and a scanner PDF of both copies with copy A's page 2 twice. Made once inside the processing server's
 * container and kept in the temp folder under a hash of everything that makes them, so both specs share them.
 */
export function scriptFiles(): Record<(typeof FILE_NAMES)[number], string> {
  const hash = createHash("sha256");
  const inputs = [
    "tests/e2e_files.py",
    "tests/synth.py",
    "tests/fixtures/copy-a.pdf",
    "tests/fixtures/copy-b.pdf",
    "tests/fixtures/codes.json",
    ...readdirSync(join(PROCESSOR, "processor")).filter((f) => f.endsWith(".py")).sort().map((f) => `processor/${f}`),
  ];
  for (const f of inputs) hash.update(f).update(readFileSync(join(PROCESSOR, f)));
  const dir = join(tmpdir(), "stem-e2e-scripts", hash.digest("hex").slice(0, 16));
  const paths = Object.fromEntries(FILE_NAMES.map((n) => [n, join(dir, n)])) as Record<(typeof FILE_NAMES)[number], string>;
  if (FILE_NAMES.every((n) => existsSync(paths[n]))) return paths;
  const made = JSON.parse(docker(["exec", "-T", "processor", "python", "tests/e2e_files.py"])) as Record<string, string>;
  mkdirSync(dir, { recursive: true });
  for (const n of FILE_NAMES) writeFileSync(paths[n], Buffer.from(made[n], "base64"));
  return paths;
}

const must = <T>(r: { data: T; error: { message: string } | null }, what: string): NonNullable<T> => {
  if (r.error || r.data === null || r.data === undefined) throw new Error(`${what} failed: ${r.error?.message ?? "no row"}`);
  return r.data as NonNullable<T>;
};

export type SeededExam = {
  examId: string;
  /** The code the database gave the exam (in script, batch and manifest numbers). */
  examCode: string;
  paperId: string;
  subjectId: number;
  venueId: string | null;
  centreId: string | null;
  title: string;
};

/**
 * An exam of the fixture paper (3 pages of its own, all answer pages; copies have 2 spare pages) that started
 * `startedMinutesAgo` minutes ago and lasts 90 minutes. A centre exam gets a venue and one centre.
 */
export async function seedExam(opts: { tag: string; title: string; sitting: "home" | "centre"; startedMinutesAgo: number; adminId: string }): Promise<SeededExam> {
  const subject = must(await svc().from("subjects").insert({ name: `E2E Scripts ${opts.tag} ${opts.sitting}`, kind: "school" }).select("id").single(), "subject insert");
  const starts = new Date(Date.now() - opts.startedMinutesAgo * 60_000);
  const title = `${opts.tag} ${opts.title}`;
  const exam = must(
    await svc()
      .from("exams")
      .insert({
        subject_id: subject.id,
        title,
        paper: "Paper 1",
        format: opts.sitting === "home" ? "online" : "in_person",
        starts_at: starts.toISOString(),
        duration_minutes: 90,
        price_pence: 1500,
        price_confirmed: true,
        booking_deadline: new Date(starts.getTime() - 86_400_000).toISOString(),
        status: "published",
        created_by: opts.adminId,
      })
      .select("id, exam_code")
      .single(),
    "exam insert",
  );
  let venueId: string | null = null;
  let centreId: string | null = null;
  if (opts.sitting === "centre") {
    venueId = must(await svc().from("venues").insert({ name: `E2E Scripts hall ${opts.tag}`, rooms: ["Hall A"] }).select("id").single(), "venue insert").id;
    centreId = must(
      await svc().from("exam_centres").insert({ exam_id: exam.id, venue_id: venueId, room: "Hall A", seat_limit: 20 }).select("id").single(),
      "centre insert",
    ).id;
  }
  const paper = must(
    await svc()
      .from("exam_papers")
      .insert({ exam_id: exam.id, kind: "paper", title: "Question paper", version: 1, storage_path: `${exam.id}/${crypto.randomUUID()}.pdf`, page_count: 3, byte_size: 1000 })
      .select("id")
      .single(),
    "paper insert",
  );
  return { examId: exam.id, examCode: exam.exam_code ?? "", paperId: paper.id, subjectId: subject.id, venueId, centreId, title };
}

/** A paid booking with its 1A copy (the fixture's code, 5 pages), and for a centre candidate a "present" mark. */
export async function seedCandidate(
  exam: SeededExam,
  studentId: string,
  code: string,
  opts: { bookedBy?: string; adminId: string },
): Promise<string> {
  const booking = must(
    await svc()
      .from("bookings")
      .insert({
        exam_id: exam.examId,
        student_id: studentId,
        booked_by: opts.bookedBy ?? studentId,
        status: "paid",
        amount_pence: 1500,
        sitting: exam.centreId ? "centre" : "home",
        ...(exam.centreId ? { centre_id: exam.centreId } : {}),
      })
      .select("id")
      .single(),
    "booking insert",
  );
  const { count } = await svc().from("paper_copies").select("*", { count: "exact", head: true }).eq("code", code);
  if ((count ?? 0) > 0) throw new Error(`the fixture code ${code} is in use by other local data`);
  must(await svc().from("paper_copies").insert({ code, booking_id: booking.id, paper_id: exam.paperId, page_count: 5 }).select("id").single(), "copy insert");
  if (exam.centreId) {
    must(
      await svc()
        .from("attendance")
        .insert({ exam_id: exam.examId, student_id: studentId, status: "present", marked_by: opts.adminId, marked_at: new Date().toISOString() })
        .select("exam_id")
        .single(),
      "attendance insert",
    );
  }
  return booking.id;
}

/** Waits for the database to reach a state (never a fixed sleep): `read` is asked every second until it matches. */
export async function waitForDb<T>(read: () => Promise<T>, expected: T, what: string, timeoutMs = 180_000): Promise<void> {
  await expect.poll(read, { message: what, timeout: timeoutMs, intervals: [1000] }).toEqual(expected);
}

/** The states of an exam's scripts, by booking. */
export async function scriptStates(examId: string): Promise<Record<string, string>> {
  const { data } = await svc().from("scripts").select("booking_id, state").eq("exam_id", examId);
  return Object.fromEntries((data ?? []).map((s) => [s.booking_id, s.state]));
}

/** The page has no sideways scroll at desktop (1440), tablet (768) and phone (390) widths. Ends at desktop width. */
export async function noSidewaysScroll(page: Page, what: string): Promise<void> {
  for (const width of [1440, 768, 390]) {
    await page.setViewportSize({ width, height: 900 });
    await expect
      .poll(() => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth), { message: `${what} at ${width} px wide` })
      .toBeLessThanOrEqual(0);
  }
  await page.setViewportSize({ width: 1440, height: 900 });
}

async function listAll(bucket: string, prefix: string): Promise<string[]> {
  const { data, error } = await svc().storage.from(bucket).list(prefix, { limit: 1000 });
  if (error) throw new Error(`listing ${bucket} failed: ${error.message}`);
  const out: string[] = [];
  for (const o of data ?? []) {
    if (o.id) out.push(`${prefix}/${o.name}`);
    else out.push(...(await listAll(bucket, `${prefix}/${o.name}`)));
  }
  return out;
}

const ids = (rows: { id: string }[] | null) => (rows ?? []).map((r) => r.id);

/** Removes an exam made by seedExam and everything hanging off it, the uploaded files and page pictures included. */
export async function removeExam(exam: SeededExam | undefined): Promise<void> {
  if (!exam) return;
  const e = exam.examId;
  const bookings = ids((await svc().from("bookings").select("id").eq("exam_id", e)).data);
  const scripts = ids((await svc().from("scripts").select("id").eq("exam_id", e)).data);
  const uploads = (await svc().from("script_uploads").select("id, storage_path").eq("exam_id", e)).data ?? [];
  const pictures = await listAll("script-pages", e);

  // The email notices the tests raised stay: the service key may only read script_notices. A family's notices go with
  // their submission (cascade); staff alerts keep only the exam's id, and the sender skips anything older than 6 hours.
  await svc().from("script_exceptions").delete().eq("exam_id", e);
  if (scripts.length) {
    await svc().from("script_page_links").delete().in("script_id", scripts);
    await svc().from("script_versions").delete().in("script_id", scripts);
    await svc().from("scripts").delete().in("id", scripts);
  }
  await svc().from("script_pages").delete().eq("exam_id", e);
  if (uploads.length) {
    await svc().from("processing_jobs").delete().in("upload_id", uploads.map((u) => u.id));
    await svc().from("script_uploads").delete().eq("exam_id", e);
  }
  await svc().from("custody_events").delete().eq("exam_id", e);
  await svc().from("scan_batches").delete().eq("exam_id", e);
  await svc().from("collection_manifests").delete().eq("exam_id", e);
  if (bookings.length) {
    await svc().from("home_submissions").delete().in("booking_id", bookings);
    await svc().from("sitting_acknowledgements").delete().in("booking_id", bookings);
    await svc().from("collection_counts").delete().in("booking_id", bookings);
    await svc().from("paper_copies").delete().in("booking_id", bookings);
  }
  await svc().from("exam_papers").delete().eq("exam_id", e);
  await svc().from("attendance").delete().eq("exam_id", e);
  await svc().from("bookings").delete().eq("exam_id", e);
  await svc().from("exam_centres").delete().eq("exam_id", e);
  const gone = await svc().from("exams").delete().eq("id", e);
  if (exam.venueId) await svc().from("venues").delete().eq("id", exam.venueId);
  await svc().from("subjects").delete().eq("id", exam.subjectId);
  const paths = uploads.map((u) => u.storage_path).filter(Boolean);
  if (paths.length) await svc().storage.from("script-uploads").remove(paths);
  if (pictures.length) await svc().storage.from("script-pages").remove(pictures);
  if (gone.error) throw new Error(`removing the exam failed: ${gone.error.message}`);
  const left = await svc().from("paper_copies").select("id").in("code", [CODE_A, CODE_B]);
  if ((left.data ?? []).length) throw new Error("the fixture copies were not removed");
}
