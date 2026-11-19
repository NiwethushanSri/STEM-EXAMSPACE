import { expect, test } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { downloadPaperCopy } from "@stem/shared";
import { PDFDocument } from "pdf-lib";
import {
  ANON_KEY,
  assertNoOwner,
  cleanup,
  clearLoginAttempts,
  countTestUsers,
  createAccount,
  signInUI,
  SUPABASE_URL,
  svc,
  type TestAccount,
} from "./admin";

// The scan check reads a generated copy in the browser and looks every code up in one call.
// Needs the paper functions served locally (supabase functions serve --env-file supabase/functions/.env.test.local).
// Every row and file it creates is removed again.

const tag = crypto.randomUUID().slice(0, 8);
const SUBJECT = `E2E Subject ${tag}`;
const VENUE = `E2E Venue ${tag}`;
const PAPER_PAGES = 3;
const SPARE = 2; // the default

let admin: TestAccount;
let student: TestAccount;
let subjectId: number;
let venueId: string;
let examId: string;
let copyBytes: Buffer;

test.describe.configure({ mode: "serial" });

async function pdf(pages: number): Promise<Buffer> {
  const doc = await PDFDocument.create();
  for (let i = 0; i < pages; i++) doc.addPage([595.28, 841.89]).drawText(`Question page ${i + 1}`, { x: 60, y: 760, size: 18 });
  return Buffer.from(await doc.save());
}

function adminClient() {
  return createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
}

async function removeData() {
  if (!examId) return;
  const { data: papers } = await svc().from("exam_papers").select("id, storage_path").eq("exam_id", examId);
  const paperIds = (papers ?? []).map((p) => p.id);
  if (paperIds.length) {
    const { data: copies } = await svc().from("paper_copies").select("id").in("paper_id", paperIds);
    const copyIds = (copies ?? []).map((c) => c.id);
    if (copyIds.length) await svc().from("paper_downloads").delete().in("copy_id", copyIds);
    await svc().from("paper_copies").delete().in("paper_id", paperIds);
    await svc().storage.from("exam-papers").remove((papers ?? []).map((p) => p.storage_path));
    await svc().from("exam_papers").delete().in("id", paperIds);
  }
  await svc().from("bookings").delete().eq("exam_id", examId);
  await svc().from("exams").delete().eq("id", examId);
}

test.beforeAll(async () => {
  await assertNoOwner();
  admin = await createAccount({ role: "admin" });
  student = await createAccount({ indexNumber: `E2E${tag.toUpperCase()}-1`, firstName: "Cand1" });
  const s = await svc().from("subjects").insert({ name: SUBJECT, kind: "school" }).select("id").single();
  if (s.error || !s.data) throw new Error(`subject insert failed: ${s.error?.message}`);
  subjectId = s.data.id;
  const v = await svc().from("venues").insert({ name: VENUE, rooms: ["Hall A"] }).select("id").single();
  if (v.error || !v.data) throw new Error(`venue insert failed: ${v.error?.message}`);
  venueId = v.data.id;
  const starts = new Date(Date.now() + 40 * 24 * 3600_000).toISOString();
  const e = await svc()
    .from("exams")
    .insert({
      subject_id: subjectId,
      title: `${tag} Scan`,
      paper: "Paper 1",
      format: "in_person",
      starts_at: starts,
      duration_minutes: 90,
      price_pence: 1500,
      price_confirmed: true,
      booking_deadline: starts,
      status: "published",
      created_by: admin.id,
    })
    .select("id")
    .single();
  if (e.error || !e.data) throw new Error(`exam insert failed: ${e.error?.message}`);
  examId = e.data.id;
  const c = await svc().from("exam_centres").insert({ exam_id: examId, venue_id: venueId, room: "Hall A", seat_limit: 20 }).select("id").single();
  if (c.error || !c.data) throw new Error(`centre insert failed: ${c.error?.message}`);
  const b = await svc()
    .from("bookings")
    .insert({ exam_id: examId, student_id: student.id, booked_by: student.id, status: "paid", amount_pence: 1500, sitting: "centre", centre_id: c.data.id });
  if (b.error) throw new Error(`booking insert failed: ${b.error.message}`);
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterAll(async () => {
  await removeData();
  await svc().from("venues").delete().like("name", `${VENUE}%`);
  await svc().from("subjects").delete().like("name", `E2E Subject ${tag}%`);
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

test("scan_check_reads_a_generated_copy", async ({ page }) => {
  // Upload the paper and make a copy exactly as an admin would.
  const client = adminClient();
  const si = await client.auth.signInWithPassword({ email: admin.email, password: admin.password });
  if (si.error) throw new Error(`admin sign-in failed: ${si.error.message}`);
  const storagePath = `${examId}/${crypto.randomUUID()}.pdf`;
  const up = await client.storage.from("exam-papers").upload(storagePath, await pdf(PAPER_PAGES), { contentType: "application/pdf", upsert: false });
  if (up.error) throw new Error(`upload failed: ${up.error.message}`);
  const reg = await client.functions.invoke("paper-register", { body: { examId, kind: "paper", storagePath } });
  if (reg.error) throw new Error(`paper-register failed: ${reg.error.message}`);
  const booking = await svc().from("bookings").select("id").eq("exam_id", examId).single();
  const copy = await downloadPaperCopy(client, { bookingId: booking.data!.id, kind: "admin_preview" }, { url: SUPABASE_URL, anonKey: ANON_KEY });
  await client.auth.signOut();
  if ("error" in copy) throw new Error(`copy failed: ${copy.error.message}`);
  const bytes = Buffer.from(await copy.data.blob.arrayBuffer());
  copyBytes = bytes;
  const total = PAPER_PAGES + SPARE;
  expect((await PDFDocument.load(bytes)).getPageCount()).toBe(total);

  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/exams");
  await page.getByRole("link", { name: "Check a scan" }).click();
  await expect(page).toHaveURL(/\/admin\/exams\/scan-check$/);

  // The file is read in the browser: only the one lookup goes out, and nothing is stored.
  const lookups: string[] = [];
  const stores: string[] = [];
  page.on("request", (r) => {
    if (r.url().includes("paper_lookup_codes")) lookups.push(r.url());
    if (r.method() !== "GET" && /storage\/v1/.test(r.url())) stores.push(r.url());
  });
  await page.locator("#scan-file").setInputFiles({ name: "copy.pdf", mimeType: "application/pdf", buffer: bytes });

  const rows = page.getByTestId("scan-row");
  await expect(rows).toHaveCount(total, { timeout: 90_000 });
  for (let n = 1; n <= total; n++) {
    await expect(rows.nth(n - 1)).toContainText(`Page ${n} of ${total}`);
    await expect(rows.nth(n - 1)).toContainText(student.indexNumber!);
    await expect(rows.nth(n - 1)).toContainText("v1");
  }
  await expect(rows.first()).toContainText(`${tag} Scan`);
  await expect(page.getByText("Older version")).toHaveCount(0);
  await expect(page.getByTestId("scan-progress")).toContainText(`Read ${total} pages, ${total} codes found`);
  expect(lookups).toHaveLength(1);
  expect(stores).toHaveLength(0);

  // A page with no code says so, and a HEIC photo is refused plainly.
  const blank = await PDFDocument.create();
  blank.addPage([595.28, 841.89]);
  await page.locator("#scan-file").setInputFiles({ name: "blank.pdf", mimeType: "application/pdf", buffer: Buffer.from(await blank.save()) });
  await expect(page.getByText("No code found on page 1")).toBeVisible({ timeout: 30_000 });
  await page.locator("#scan-file").setInputFiles({ name: "photo.heic", mimeType: "image/heic", buffer: Buffer.from("x") });
  await expect(page.getByRole("alert").filter({ hasText: "HEIC photos are not supported. Export as JPEG or PNG and try again." })).toBeVisible();
});

test("scan_check_keeps_the_reading_when_the_lookup_fails", async ({ page }) => {
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/exams/scan-check");
  const total = PAPER_PAGES + SPARE;
  let calls = 0;
  await page.route("**/rest/v1/rpc/paper_lookup_codes", (route) => {
    calls++;
    return calls === 1 ? route.abort() : route.continue();
  });
  await page.locator("#scan-file").setInputFiles({ name: "copy.pdf", mimeType: "application/pdf", buffer: copyBytes });
  await expect(page.getByRole("alert").filter({ hasText: "could not be looked up" })).toBeVisible({ timeout: 90_000 });
  const rows = page.getByTestId("scan-row");
  await expect(rows).toHaveCount(total);
  await expect(rows.first()).toContainText("not looked up yet");
  await page.getByRole("button", { name: "Try the lookup again" }).click();
  await expect(rows.first()).toContainText(student.indexNumber!);
  await expect(rows.nth(total - 1)).toContainText(`Page ${total} of ${total}`);
  expect(calls).toBe(2);
});
