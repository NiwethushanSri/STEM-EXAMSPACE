import { expect, test, type Page } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { PDFDocument } from "pdf-lib";
import {
  ANON_KEY,
  assertNoOwner,
  BASE,
  cleanup,
  clearLoginAttempts,
  countTestUsers,
  createAccount,
  signInUI,
  SUPABASE_URL,
  svc,
  type TestAccount,
} from "./admin";

// Family paper downloads on "My bookings". Needs the paper functions served locally
// (supabase functions serve --env-file supabase/functions/.env.test.local).
// Serial: the tests build on one exam and its paper. Every row and file it creates is removed again.

const tag = crypto.randomUUID().slice(0, 8);
const SUBJECT = `E2E Subject ${tag}`;
const VENUE = `E2E Venue ${tag}`;
const MIN = 60_000;

// Next year's first Saturday of June (BST) and of December (GMT), starting 09:00 London time.
const Y = new Date().getUTCFullYear() + 1;
function firstSaturday(month0: number, hourUtc: number): Date {
  const d = new Date(Date.UTC(Y, month0, 1, hourUtc));
  while (d.getUTCDay() !== 6) d.setUTCDate(d.getUTCDate() + 1);
  return d;
}
const SUMMER = firstSaturday(5, 8);
const WINTER = firstSaturday(11, 9);
const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
/** The release is 10 minutes before the 09:00 London start: "08:50 on Saturday 5 June". */
const readyText = (d: Date) => `Your paper will be ready at 08:50 on Saturday ${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`;

let adminAccount: TestAccount;
let subjectId: number;
let venueId: string;
let centreId: string;
let openExam: string; // released (starts in about 5 minutes), home
const examIds: string[] = [];

async function pdf(pages: number, label: string): Promise<Buffer> {
  const doc = await PDFDocument.create();
  for (let i = 0; i < pages; i++) doc.addPage([595.28, 841.89]).drawText(`${label} page ${i + 1}`, { x: 60, y: 760, size: 18 });
  return Buffer.from(await doc.save());
}

async function makeExam(title: string, starts: Date, format: "online" | "in_person", releaseMinutes = 10, paper = "Paper 1"): Promise<string> {
  const { data, error } = await svc()
    .from("exams")
    .insert({
      subject_id: subjectId,
      title: `${tag} ${title}`,
      paper,
      format,
      starts_at: starts.toISOString(),
      duration_minutes: 90,
      price_pence: 1500,
      price_confirmed: true,
      booking_deadline: starts.toISOString(),
      status: "published",
      release_minutes_before: releaseMinutes,
      created_by: adminAccount.id,
    })
    .select("id")
    .single();
  if (error || !data) throw new Error(`exam insert failed: ${error?.message}`);
  examIds.push(data.id);
  if (format === "in_person") {
    const c = await svc().from("exam_centres").insert({ exam_id: data.id, venue_id: venueId, room: "Hall A", seat_limit: 20 }).select("id").single();
    if (c.error || !c.data) throw new Error(`centre insert failed: ${c.error?.message}`);
    centreId = c.data.id;
  }
  return data.id;
}

async function book(examId: string, student: TestAccount, sitting: "home" | "centre", status: "paid" | "awaiting_payment" = "paid") {
  const { error } = await svc()
    .from("bookings")
    .insert({
      exam_id: examId,
      student_id: student.id,
      booked_by: student.id,
      status,
      amount_pence: 1500,
      sitting,
      ...(sitting === "centre" ? { centre_id: centreId } : {}),
    });
  if (error) throw new Error(`booking insert failed: ${error.message}`);
}

/** Uploads a PDF with the admin's own session and registers it, as the admin page does. */
async function registerPaper(examId: string, kind: "paper" | "insert", bytes: Buffer, extra: { title?: string; reason?: string } = {}) {
  const client = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const si = await client.auth.signInWithPassword({ email: adminAccount.email, password: adminAccount.password });
  if (si.error) throw new Error(`admin sign-in failed: ${si.error.message}`);
  const storagePath = `${examId}/${crypto.randomUUID()}.pdf`;
  const up = await client.storage.from("exam-papers").upload(storagePath, bytes, { contentType: "application/pdf", upsert: false });
  if (up.error) throw new Error(`upload failed: ${up.error.message}`);
  const res = await client.functions.invoke("paper-register", { body: { examId, kind, storagePath, ...extra } });
  await client.auth.signOut();
  if (res.error) throw new Error(`paper-register failed: ${res.error.message}`);
}

async function removeData() {
  if (examIds.length === 0) return;
  const { data: papers } = await svc().from("exam_papers").select("id, storage_path").in("exam_id", examIds);
  const paperIds = (papers ?? []).map((p) => p.id);
  if (paperIds.length) {
    const { data: copies } = await svc().from("paper_copies").select("id").in("paper_id", paperIds);
    const copyIds = (copies ?? []).map((c) => c.id);
    if (copyIds.length) await svc().from("paper_downloads").delete().in("copy_id", copyIds);
    await svc().from("paper_copies").delete().in("paper_id", paperIds);
    await svc().storage.from("exam-papers").remove((papers ?? []).map((p) => p.storage_path));
    await svc().from("exam_papers").delete().in("id", paperIds);
  }
  await svc().from("bookings").delete().in("exam_id", examIds);
  await svc().from("exams").delete().in("id", examIds);
  examIds.length = 0;
}

/** Signs in through the form and waits until the sign-in has landed. */
async function signIn(page: Page, a: TestAccount) {
  await signInUI(page, a.email, a.password);
  await expect(page).not.toHaveURL(/\/login/);
}

test.describe.configure({ mode: "serial" });

test.beforeAll(async () => {
  await assertNoOwner();
  adminAccount = await createAccount({ role: "admin" });
  const s = await svc().from("subjects").insert({ name: SUBJECT, kind: "school" }).select("id").single();
  if (s.error || !s.data) throw new Error(`subject insert failed: ${s.error?.message}`);
  subjectId = s.data.id;
  const v = await svc().from("venues").insert({ name: VENUE, rooms: ["Hall A"] }).select("id").single();
  if (v.error || !v.data) throw new Error(`venue insert failed: ${v.error?.message}`);
  venueId = v.data.id;
  // Starts in an hour with release 2 hours before: released now, and the window stays open well beyond the suite.
  openExam = await makeExam("Open", new Date(Date.now() + 60 * MIN), "online", 120);
  await registerPaper(openExam, "paper", await pdf(2, "Question"));
  for (const path of ["/login", "/account/bookings"]) await fetch(`${BASE}${path}`, { redirect: "manual" }).catch(() => undefined);
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterAll(async () => {
  await removeData();
  await svc().from("venues").delete().eq("id", venueId);
  await svc().from("subjects").delete().eq("id", subjectId);
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

test("home_candidate_downloads_after_release", async ({ page }) => {
  const student = await createAccount({ status: "active", firstName: "Cora" });
  await book(openExam, student, "home");
  await signIn(page, student);
  await page.goto("/account/bookings");

  const paper = page.getByTestId("booking-paper");
  await expect(paper.getByTestId("paper-message")).toHaveText("Your paper is ready to download.");
  await expect(paper.getByTestId("paper-downloaded")).toHaveCount(0);

  const [download] = await Promise.all([page.waitForEvent("download"), paper.getByRole("button", { name: /^Download paper for / }).click()]);
  expect(download.suggestedFilename()).toMatch(/\.pdf$/);
  await expect(paper.getByTestId("paper-downloaded")).toHaveText(/^Downloaded at \d{2}:\d{2} by Cora Tester$/);
  // The button is back to normal and offers a second download.
  await expect(paper.getByRole("button", { name: /^Download again for / })).toBeEnabled();

  // A held release stops the download and says so.
  await svc().from("exams").update({ release_held: true }).eq("id", openExam);
  await page.reload();
  await expect(page.getByTestId("paper-message")).toHaveText("The paper is paused by the institution. Please wait.");
  await expect(page.getByRole("button", { name: /Download/ })).toHaveCount(0);
  await svc().from("exams").update({ release_held: false }).eq("id", openExam);

  // An insert is listed under the paper with its own button.
  await registerPaper(openExam, "insert", await pdf(1, "Formula sheet"), { title: "Formula sheet" });
  await page.reload();
  const insert = page.getByTestId("paper-insert");
  await expect(insert).toContainText("Formula sheet");
  const [insertDownload] = await Promise.all([page.waitForEvent("download"), insert.getByRole("button", { name: /^Download Formula sheet for / }).click()]);
  expect(insertDownload.suggestedFilename()).toMatch(/\.pdf$/);

  // A replaced paper asks for a corrected download; downloading it clears the notice.
  await registerPaper(openExam, "paper", await pdf(3, "Corrected"), { reason: "Typo on page two" });
  await page.reload();
  await expect(page.getByTestId("paper-message")).toHaveText("A corrected paper is available. Download it again.");
  await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: /^Download corrected paper for / }).click()]);
  await expect(page.getByTestId("paper-message")).toHaveText("Your paper is ready to download.");
  await expect(page.getByTestId("paper-downloaded")).toContainText("by Cora Tester");
});

test("parent_downloads_for_child", async ({ page }) => {
  const child = await createAccount({ status: "active", firstName: "Chip" });
  const parent = await createAccount({ role: "parent", firstName: "Pia" });
  const { error } = await svc().from("parent_children").insert({ parent_id: parent.id, student_id: child.id });
  if (error) throw new Error(`link failed: ${error.message}`);
  await book(openExam, child, "home");
  await signIn(page, parent);
  await page.goto("/account/bookings");

  const row = page.getByTestId("booking-row").filter({ hasText: "For Chip Tester" });
  await expect(row.getByTestId("paper-message")).toHaveText("Your paper is ready to download.");
  await expect(row.getByRole("button", { name: /^Download paper for .*, Chip Tester$/ })).toBeVisible();
  const [download] = await Promise.all([page.waitForEvent("download"), row.getByRole("button", { name: /^Download paper for / }).click()]);
  expect(download.suggestedFilename()).toMatch(/\.pdf$/);
  await expect(row.getByTestId("paper-downloaded")).toHaveText(/^Downloaded at \d{2}:\d{2} by Pia Tester$/);
});

test("before_release_shows_ready_time", async ({ page }) => {
  const summer = await makeExam("Summer", SUMMER, "online");
  const winter = await makeExam("Winter", WINTER, "online");
  const student = await createAccount({ status: "active", firstName: "Sam" });
  await book(summer, student, "home");
  await book(winter, student, "home");
  await signIn(page, student);
  await page.goto("/account/bookings");

  // Upcoming bookings come in date order: June, then December.
  const rows = page.getByTestId("booking-row");
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0).getByTestId("paper-message")).toHaveText(readyText(SUMMER));
  await expect(rows.nth(1).getByTestId("paper-message")).toHaveText(readyText(WINTER));
  await expect(page.getByRole("button", { name: /Download/ })).toHaveCount(0);
});

test("same_subject_bookings_have_different_accessible_names", async ({ page }) => {
  // Same subject, same title, different paper, same child: the labels must still differ.
  const p1 = await makeExam("Maths", new Date(Date.now() + 60 * MIN), "online", 120, "Paper 1");
  const p2 = await makeExam("Maths", new Date(Date.now() + 90 * MIN), "online", 120, "Paper 2");
  await registerPaper(p1, "paper", await pdf(1, "One"));
  await registerPaper(p2, "paper", await pdf(1, "Two"));
  const child = await createAccount({ status: "active", firstName: "Dee" });
  const parent = await createAccount({ role: "parent", firstName: "Pru" });
  const { error } = await svc().from("parent_children").insert({ parent_id: parent.id, student_id: child.id });
  if (error) throw new Error(`link failed: ${error.message}`);
  await book(p1, child, "home");
  await book(p2, child, "home");
  await signIn(page, parent);
  await page.goto("/account/bookings");
  const buttons = page.getByRole("button", { name: /^Download paper for / });
  await expect(buttons).toHaveCount(2);
  const names = await buttons.evaluateAll((els) => els.map((e) => e.getAttribute("aria-label")));
  expect(new Set(names).size).toBe(2);
  expect(names.join("|")).toContain("Paper 1");
  expect(names.join("|")).toContain("Paper 2");
  expect(names.every((n) => n?.endsWith("Dee Tester"))).toBe(true);
  await expect(page.locator("section[aria-label^='Paper for ']")).toHaveCount(2);
});

test("centre_booking_shows_exam_room_message", async ({ page }) => {
  const exam = await makeExam("Centre", new Date(Date.now() + 60 * MIN), "in_person", 120);
  const student = await createAccount({ status: "active", firstName: "Cleo" });
  const unpaid = await createAccount({ status: "active", firstName: "Una" });
  await book(exam, student, "centre");
  await book(openExam, unpaid, "home", "awaiting_payment");
  await signIn(page, student);
  await page.goto("/account/bookings");
  await expect(page.getByTestId("paper-message")).toHaveText("Your booking is for the centre; your paper is handed out in the exam room");
  await expect(page.getByRole("button", { name: /Download/ })).toHaveCount(0);

  // An unpaid booking has no paper section at all.
  await page.context().clearCookies();
  await signIn(page, unpaid);
  await page.goto("/account/bookings");
  await expect(page.getByTestId("booking-row")).toHaveCount(1);
  await expect(page.getByTestId("booking-paper")).toHaveCount(0);
});
