import { readFileSync } from "node:fs";
import { expect, test, type Page } from "@playwright/test";
import { PDFDocument } from "pdf-lib";
import {
  assertNoOwner,
  BASE,
  cleanup,
  clearLoginAttempts,
  countTestUsers,
  createAccount,
  signInUI,
  svc,
  type TestAccount,
} from "./admin";
import { formatLondon } from "../src/lib/money";

// The admin exam page: upload and replace the paper, release settings, print packs and reprints.
// Needs the paper functions served locally (supabase functions serve --env-file supabase/functions/.env.test.local).
// Serial. Every row and file it creates is removed again.

const tag = crypto.randomUUID().slice(0, 8);
const SUBJECT = `E2E Subject ${tag}`;
const VENUE = `E2E Venue ${tag}`;
const HOURS = 3600_000;
const startsAt = new Date(Date.now() + 40 * 24 * HOURS).toISOString();
const soonAt = new Date(Date.now() + 12 * HOURS).toISOString();
const PAPER_PAGES = 2;
const SPARE = 2; // the default

let admin: TestAccount;
let subjectId: number;
let venueId: string;
let examId: string;
let centreId: string;
const students: TestAccount[] = [];

/** A PDF of n A4 pages made here, never a fixture on disk. */
async function pdf(pages: number): Promise<Buffer> {
  const doc = await PDFDocument.create();
  for (let i = 0; i < pages; i++) doc.addPage([595.28, 841.89]).drawText(`Question page ${i + 1}`, { x: 60, y: 760, size: 18 });
  return Buffer.from(await doc.save());
}

/** The text of a PDF's first page. pdfjs is an ES module, so it is loaded with a real dynamic import. */
async function firstPageText(bytes: Buffer): Promise<string> {
  const load = new Function("m", "return import(m)") as (m: string) => Promise<typeof import("pdfjs-dist")>;
  const pdfjs = await load("pdfjs-dist/legacy/build/pdf.mjs");
  const doc = await pdfjs.getDocument({ data: new Uint8Array(bytes) }).promise;
  const content = await (await doc.getPage(1)).getTextContent();
  return content.items.map((i) => ("str" in i ? i.str : "")).join(" ");
}

async function makeExam(title: string, starts: string, withCentre: boolean): Promise<string> {
  const { data, error } = await svc()
    .from("exams")
    .insert({
      subject_id: subjectId,
      title: `${tag} ${title}`,
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
  if (error || !data) throw new Error(`exam insert failed: ${error?.message}`);
  if (withCentre) {
    const c = await svc().from("exam_centres").insert({ exam_id: data.id, venue_id: venueId, room: "Hall A", seat_limit: 20 }).select("id").single();
    if (c.error || !c.data) throw new Error(`centre insert failed: ${c.error?.message}`);
    centreId = c.data.id;
  }
  return data.id;
}

async function book(student: TestAccount, status: "paid" | "awaiting_payment" | "cancel_requested", sitting: "centre" | "home" = "centre") {
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

async function removeData() {
  const { data } = await svc().from("exams").select("id").like("title", `${tag}%`);
  const ids = (data ?? []).map((e) => e.id);
  if (ids.length === 0) return;
  const { data: papers } = await svc().from("exam_papers").select("id, storage_path").in("exam_id", ids);
  const paperIds = (papers ?? []).map((p) => p.id);
  if (paperIds.length) {
    const { data: copies } = await svc().from("paper_copies").select("id").in("paper_id", paperIds);
    const copyIds = (copies ?? []).map((c) => c.id);
    if (copyIds.length) await svc().from("paper_downloads").delete().in("copy_id", copyIds);
    await svc().from("paper_copies").delete().in("paper_id", paperIds);
    await svc().storage.from("exam-papers").remove((papers ?? []).map((p) => p.storage_path));
  }
  await svc().from("bookings").delete().in("exam_id", ids);
  await svc().from("exams").delete().in("id", ids);
}

async function signInAdmin(page: Page) {
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
}

async function openExamPage(page: Page) {
  await page.goto(`/admin/exams/${examId}`);
  await expect(page.getByRole("heading", { name: new RegExp(`${tag} Maths`) })).toBeVisible();
}

// The tests build on each other (the paper, then its copies), so a failure skips the rest.
test.describe.configure({ mode: "serial" });

test.beforeAll(async () => {
  await assertNoOwner();
  admin = await createAccount({ role: "admin" });
  const s = await svc().from("subjects").insert({ name: SUBJECT, kind: "school" }).select("id").single();
  if (s.error || !s.data) throw new Error(`subject insert failed: ${s.error?.message}`);
  subjectId = s.data.id;
  const v = await svc().from("venues").insert({ name: VENUE, rooms: ["Hall A"] }).select("id").single();
  if (v.error || !v.data) throw new Error(`venue insert failed: ${v.error?.message}`);
  venueId = v.data.id;
  examId = await makeExam("Maths", startsAt, true);
  await makeExam("Soon", soonAt, false);
  // Created out of index order on purpose: the pack must follow the index numbers.
  for (const n of [3, 1, 2, 4]) {
    students.push(await createAccount({ indexNumber: `E2E${tag.toUpperCase()}-${n}`, firstName: `Cand${n}` }));
  }
  for (const path of ["/login", "/admin", "/admin/exams", `/admin/exams/${examId}`]) {
    await fetch(`${BASE}${path}`, { redirect: "manual" }).catch(() => undefined);
  }
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

test("admin_uploads_paper_and_sees_version_1", async ({ page }) => {
  await signInAdmin(page);

  // The home page and the list warn about a published exam with no paper close to its release time.
  await expect(page.getByTestId("missing-papers")).toContainText(`${tag} Soon`);
  await expect(page.getByTestId("missing-papers")).not.toContainText(`${tag} Maths`);
  await page.goto("/admin/exams");
  const soonRow = page.getByTestId("exam-row").filter({ hasText: `${tag} Soon` });
  await expect(soonRow).toContainText("No paper uploaded");
  const mathsRow = page.getByTestId("exam-row").filter({ hasText: `${tag} Maths` });
  await expect(mathsRow).not.toContainText("No paper uploaded");

  await mathsRow.getByRole("link", { name: "Paper and print" }).click();
  await expect(page).toHaveURL(new RegExp(`/admin/exams/${examId}$`));
  await expect(page.getByText("No paper has been uploaded yet.")).toBeVisible();
  // The release time is the start minus 10 minutes, in London time.
  const release = new Date(Date.parse(startsAt) - 10 * 60_000).toISOString();
  await expect(page.getByTestId("release-time")).toContainText(formatLondon(release));
  await expect(page.getByTestId("release-status")).toContainText("Scheduled");

  await page.getByRole("button", { name: "Upload paper" }).click();
  await page.locator("input[type=file]").setInputFiles({ name: "paper.pdf", mimeType: "application/pdf", buffer: await pdf(PAPER_PAGES) });
  await page.getByRole("dialog").getByRole("button", { name: "Upload", exact: true }).click();

  await expect(page.getByRole("status").filter({ hasText: "Paper version 1 uploaded" })).toBeVisible();
  const versions = page.getByTestId("paper-version");
  await expect(versions).toHaveCount(1);
  await expect(versions.first()).toContainText("v1");
  await expect(versions.first()).toContainText("Current");
  await expect(page.getByTestId("current-paper")).toContainText("Version 1");

  const { data: rows } = await svc().from("exam_papers").select("version, page_count, kind, storage_path, superseded_at").eq("exam_id", examId);
  expect(rows).toHaveLength(1);
  expect(rows?.[0]).toMatchObject({ version: 1, page_count: PAPER_PAGES, kind: "paper", superseded_at: null });
  expect(rows?.[0].storage_path.startsWith(`${examId}/`)).toBe(true);

  // Hold needs a reason, then Resume lifts it.
  await page.getByRole("button", { name: "Hold", exact: true }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Hold release" }).click();
  await expect(page.getByText("Give a reason of 3 to 300 characters.")).toBeVisible();
  await page.getByRole("dialog").getByLabel("Reason").fill("Printer fault");
  await page.getByRole("dialog").getByRole("button", { name: "Hold release" }).click();
  await expect(page.getByTestId("release-status")).toContainText("Held");
  await page.getByRole("button", { name: "Resume" }).click();
  await page.getByRole("dialog").getByLabel("Reason").fill("Printer fixed");
  await page.getByRole("dialog").getByRole("button", { name: "Resume release" }).click();
  await expect(page.getByTestId("release-status")).toContainText("Scheduled");
});

/** The exam's current paper counts as checked: an admin saved its page roles (no pack or reprint is made before). */
async function rolesChecked() {
  const r = await svc().from("exam_papers").update({ pages_reviewed_at: new Date().toISOString() })
    .eq("exam_id", examId).eq("kind", "paper").is("superseded_at", null);
  if (r.error) throw new Error(`page roles could not be marked checked: ${r.error.message}`);
}

test("replace_requires_reason_after_download", async ({ page }) => {
  const paper = await svc().from("exam_papers").select("id").eq("exam_id", examId).eq("version", 1).maybeSingle();
  expect(paper.data).not.toBeNull();
  await book(students[1], "paid");
  await signInAdmin(page);
  await openExamPage(page);

  // No pack is made before the page roles are checked: the screen says what to do.
  await expect(page.getByTestId("print-roles-first")).toContainText("Check the page roles first");
  await expect(page.getByRole("button", { name: "Print pack" })).toBeDisabled();
  await rolesChecked();
  await page.reload();
  await expect(page.getByTestId("print-roles-first")).toHaveCount(0);

  // Make a copy (a print pack), so replacing the paper now needs a reason.
  await page.getByRole("button", { name: "Print pack" }).click();
  await expect(page.getByText("Pack saved: 1 copy.")).toBeVisible();
  const copies = await svc().from("paper_copies").select("id", { count: "exact", head: true }).eq("paper_id", paper.data!.id);
  expect(copies.count).toBe(1);
  await expect(page.getByTestId("download-row")).toHaveCount(1);
  await expect(page.getByTestId("download-row").first()).toContainText("Print pack");
  await expect(page.getByTestId("download-row").first()).toContainText(students[1].indexNumber!);
  await expect(page.getByTestId("download-row").first()).toContainText("Casey Tester");
  await expect(page.getByTestId("download-row").first()).toContainText("v1");
  // The exam code is locked once a copy exists.
  await expect(page.getByLabel("Exam code")).toBeDisabled();

  await page.getByRole("button", { name: "Replace paper" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog.getByLabel("Reason for replacing")).toBeVisible();
  await dialog.locator("input[type=file]").setInputFiles({ name: "paper2.pdf", mimeType: "application/pdf", buffer: await pdf(3) });
  await dialog.getByRole("button", { name: "Upload", exact: true }).click();
  await expect(dialog.getByRole("alert")).toContainText("Give a reason of 3 to 300 characters.");
  // Nothing was uploaded or registered without the reason.
  const still = await svc().from("exam_papers").select("version").eq("exam_id", examId);
  expect(still.data).toHaveLength(1);

  await dialog.getByLabel("Reason for replacing").fill("Question 4 had a typing error");
  await dialog.getByRole("button", { name: "Upload", exact: true }).click();
  await expect(page.getByRole("status").filter({ hasText: "Paper version 2 uploaded" })).toBeVisible();
  const versions = page.getByTestId("paper-version");
  await expect(versions).toHaveCount(2);
  await expect(versions.nth(0)).toContainText("v2");
  await expect(versions.nth(0)).toContainText("Question 4 had a typing error");
  await expect(versions.nth(1)).toContainText("v1");
  await expect(versions.nth(1)).not.toContainText("Current");

  // A reprint now uses the corrected paper and the screen says so (the new version's roles are checked first).
  await rolesChecked();
  await page.reload();
  await page.getByText("Candidates and reprints").click();
  await page.getByRole("button", { name: `Reprint ${students[1].indexNumber}` }).click();
  await expect(page.getByText("This reprint uses the corrected paper (version 2) and differs from the pack you printed.")).toBeVisible();
  await expect(page.getByTestId("download-row").first()).toContainText("Reprint");
  await expect(page.getByTestId("download-row").first()).toContainText("v2");
});

test("print_pack_has_cover_and_all_centre_candidates", async ({ page }) => {
  // Candidates 3, 1 and 2 hold a seat (2 has asked to cancel); 4 has not paid.
  const [c3, c1, c2, c4] = students;
  // c1 was booked by the test before this one.
  await book(c3, "paid");
  await book(c2, "cancel_requested");
  await book(c4, "awaiting_payment");
  expect(c1.id).toBe(students[1].id);

  await signInAdmin(page);
  await openExamPage(page);
  const centre = page.getByTestId("print-centre");
  await expect(centre).toContainText("3 candidates");
  await centre.getByText("Candidates and reprints").click();
  const order = (await centre.getByTestId("candidate-row").allInnerTexts()).map((t) => /E2E[0-9A-Z]+-\d/.exec(t)?.[0]);
  expect(order).toEqual([1, 2, 3].map((n) => `E2E${tag.toUpperCase()}-${n}`));

  const downloadPromise = page.waitForEvent("download");
  await centre.getByRole("button", { name: "Print pack" }).click();
  const download = await downloadPromise;
  expect(download.suggestedFilename()).toMatch(/print-pack\.pdf$/);
  const path = await download.path();
  const bytes = readFileSync(path);
  const doc = await PDFDocument.load(bytes);
  // The paper is now version 2 (3 pages); each copy has its 3 pages plus 2 spare answer pages; the cover is first.
  expect(doc.getPageCount()).toBe(1 + 3 * (3 + SPARE));
  // The cover is the first page: it names the exam code, the centre and the paper version.
  const code = await svc().from("exams").select("exam_code").eq("id", examId).single();
  const cover = await firstPageText(bytes);
  expect(cover).toContain(code.data!.exam_code);
  expect(cover).toContain(VENUE);
  expect(cover).toContain("Hall A");
  expect(cover).toMatch(/Candidates\s+3/);
  expect(cover).toMatch(/Paper version\s+2/);
  await expect(page.getByText("Pack saved: 3 copies.")).toBeVisible();

  // Every candidate has exactly one copy of the current version.
  const current = await svc().from("exam_papers").select("id").eq("exam_id", examId).is("superseded_at", null).single();
  const made = await svc().from("paper_copies").select("booking_id", { count: "exact", head: true }).eq("paper_id", current.data!.id);
  expect(made.count).toBe(3);
});

test("print_pack_names_the_candidate_that_failed_and_saves_nothing", async ({ page }) => {
  await signInAdmin(page);
  await openExamPage(page);
  // Fail the second candidate's copy only.
  let calls = 0;
  await page.route("**/functions/v1/paper-copy", async (route) => {
    calls++;
    if (calls === 2) return route.fulfill({ status: 500, contentType: "application/json", body: JSON.stringify({ error: { code: "internal", message: "x" } }) });
    return route.continue();
  });
  let saved = false;
  page.on("download", () => (saved = true));
  await page.getByRole("button", { name: "Print pack" }).click();
  const alert = page.getByRole("alert").filter({ hasText: "The pack was not made." });
  await expect(alert).toContainText(`candidate E2E${tag.toUpperCase()}-`);
  await expect(alert).not.toContainText("Cand");
  await expect(alert.getByRole("button", { name: "Retry" })).toBeVisible();
  expect(saved).toBe(false);

  // Retry with the failure gone saves the pack.
  await page.unroute("**/functions/v1/paper-copy");
  const downloadPromise = page.waitForEvent("download");
  await alert.getByRole("button", { name: "Retry" }).click();
  await downloadPromise;
  await expect(page.getByText("Pack saved: 3 copies.")).toBeVisible();
});

test("print_pack_with_copies_of_two_versions_is_not_saved", async ({ page }) => {
  await signInAdmin(page);
  await openExamPage(page);
  // One copy reports another paper version, as if the paper were replaced while the pack was being made.
  let calls = 0;
  await page.route("**/functions/v1/paper-copy", async (route) => {
    const res = await route.fetch();
    calls++;
    const headers = { ...res.headers() };
    if (calls === 2) headers["x-paper-version"] = "99";
    return route.fulfill({ response: res, headers });
  });
  let saved = false;
  page.on("download", () => (saved = true));
  await page.getByRole("button", { name: "Print pack" }).click();
  const alert = page.getByRole("alert").filter({ hasText: "The paper was replaced while this pack was being made" });
  await expect(alert).toContainText("Nothing was saved. Make the pack again.");
  expect(saved).toBe(false);
  await page.unroute("**/functions/v1/paper-copy");
  const downloadPromise = page.waitForEvent("download");
  await alert.getByRole("button", { name: "Make the pack again" }).click();
  await downloadPromise;
  await expect(page.getByText("Pack saved: 3 copies.")).toBeVisible();
});

test("teacher_has_no_way_into_the_exam_paper_page", async ({ page }) => {
  const teacher = await createAccount({ role: "teacher" });
  await signInUI(page, teacher.email, teacher.password);
  await expect(page).toHaveURL(/\/teacher$/);
  await page.goto("/teacher/exams");
  await expect(page.getByRole("heading", { name: "Exams", exact: true })).toBeVisible();
  await expect(page.locator("a[href^='/admin/exams']")).toHaveCount(0);
  await expect(page.getByText("Paper and print")).toHaveCount(0);
  await page.goto(`/admin/exams/${examId}`);
  await expect(page).not.toHaveURL(/\/admin\//);
});

test("release_minutes_change_on_published_exam_asks_for_a_reason", async ({ page }) => {
  await signInAdmin(page);
  await openExamPage(page);
  const form = page.getByRole("form", { name: "Paper settings" });
  await form.getByLabel("Release minutes before the start").fill("30");
  await form.getByRole("button", { name: "Save settings" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("Families will get the paper 30 minutes before the start instead of 10.");
  await dialog.getByRole("button", { name: "Save settings" }).click();
  await expect(dialog.getByText("Give a reason of 3 to 300 characters.")).toBeVisible();
  const before = await svc().from("exams").select("release_minutes_before").eq("id", examId).single();
  expect(before.data?.release_minutes_before).toBe(10);
  await dialog.getByLabel("Reason").fill("Room opens earlier");
  await dialog.getByRole("button", { name: "Save settings" }).click();
  await expect(page.getByRole("status").filter({ hasText: "Paper settings saved." })).toBeVisible();
  const release = new Date(Date.parse(startsAt) - 30 * 60_000).toISOString();
  await expect(page.getByTestId("release-time")).toContainText(formatLondon(release));
  const audit = await svc()
    .from("audit_log")
    .select("reason")
    .eq("action", "exam_paper_settings_changed")
    .eq("target_id", examId)
    .eq("actor_id", admin.id)
    .order("created_at", { ascending: false })
    .limit(1)
    .single();
  expect(audit.data?.reason).toMatch(/; release 10 -> 30 minutes before the start; spare pages 2 -> 2; reason: Room opens earlier$/);
  // Spare pages alone need no reason.
  await form.getByLabel("Spare answer pages").fill("3");
  await form.getByRole("button", { name: "Save settings" }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.getByRole("status").filter({ hasText: "Paper settings saved." })).toBeVisible();
  await svc().from("exams").update({ release_minutes_before: 10, spare_pages: SPARE }).eq("id", examId);
});
