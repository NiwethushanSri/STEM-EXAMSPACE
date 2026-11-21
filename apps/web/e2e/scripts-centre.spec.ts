import { expect, test, type Page } from "@playwright/test";
import { assertNoOwner, cleanup, clearLoginAttempts, countTestUsers, createAccount, signInUI, svc, type TestAccount } from "./admin";
import {
  CODE_A,
  CODE_B,
  noSidewaysScroll,
  removeExam,
  requireProcessor,
  scriptFiles,
  scriptStates,
  seedCandidate,
  seedExam,
  waitForDb,
  type SeededExam,
} from "./scripts";

// A centre exam end to end (Phase 2): staff count the sheets, record custody and print the collection manifest; upload
// a scanner's PDF of both candidates' copies (copy A's page 2 scanned twice) that the real processing server reads;
// see the totals; declare the centre's scans complete; settle the duplicate in the exception queue; and find both
// scripts verified. Needs the processing server (npm run e2e:local starts it).
// Serial: the tests build on one exam. Every row and file it makes is removed again.

test.describe.configure({ mode: "serial" });

const tag = crypto.randomUUID().slice(0, 8);
const indexA = `SE-2026-${7000 + Math.floor(Math.random() * 499)}`;
const indexB = `SE-2026-${7500 + Math.floor(Math.random() * 499)}`;

let admin: TestAccount;
let exam: SeededExam | undefined;
let bookingA: string;
let bookingB: string;
let files: ReturnType<typeof scriptFiles>;

async function signIn(page: Page, a: TestAccount) {
  await signInUI(page, a.email, a.password);
  await expect(page).not.toHaveURL(/\/login/);
}

test.beforeAll(async () => {
  test.setTimeout(240_000);
  await assertNoOwner();
  requireProcessor();
  files = scriptFiles();
  admin = await createAccount({ role: "admin", firstName: `Ada${tag}` });
  const a = await createAccount({ status: "active", firstName: `Cara${tag}`, indexNumber: indexA });
  const b = await createAccount({ status: "active", firstName: `Dev${tag}`, indexNumber: indexB });
  // Started 2 hours ago (finished 30 minutes ago); both candidates were marked present.
  exam = await seedExam({ tag, title: "Centre scripts", sitting: "centre", startedMinutesAgo: 120, adminId: admin.id });
  bookingA = await seedCandidate(exam, a.id, CODE_A, { adminId: admin.id });
  bookingB = await seedCandidate(exam, b.id, CODE_B, { adminId: admin.id });
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterAll(async () => {
  await removeExam(exam);
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

test("staff_count_sheets_record_custody_and_print_the_manifest", async ({ page }) => {
  await signIn(page, admin);
  await page.goto(`/admin/attendance/${exam!.examId}?centre=${exam!.centreId}`);

  for (const [index, extra, text] of [
    [indexA, "1", "Booklet + 1 extra sheet"],
    [indexB, "0", "Booklet + 0 extra sheets"],
  ] as const) {
    const row = page.getByTestId("collection-row").filter({ hasText: index });
    await row.getByLabel(`Extra sheets for ${index}`).fill(extra);
    await row.getByRole("button", { name: "Save" }).click();
    await expect(row.getByTestId("sheets-text")).toHaveText(text);
  }

  const custody = page.getByRole("form", { name: "Record handover" });
  await custody.getByLabel("Step").selectOption({ label: "Collected" });
  await custody.getByLabel("Place").fill("Exam hall");
  await custody.getByLabel(/^Note/).fill("Collected from the hall by the invigilator");
  await custody.getByRole("button", { name: "Record handover" }).click();
  await expect(page.getByTestId("custody-list")).toContainText("Collected · Exam hall");

  const [download] = await Promise.all([page.waitForEvent("download"), page.getByRole("button", { name: "Print collection manifest" }).click()]);
  expect(download.suggestedFilename()).toBe(`M-${exam!.examCode}-01.pdf`);
  await expect(page.getByText(`Manifest M-${exam!.examCode}-01 made.`, { exact: true })).toBeVisible();
  await noSidewaysScroll(page, "the register with sheets and custody");
});

test("staff_upload_a_scan_batch_see_the_totals_and_complete_the_centre", async ({ page }) => {
  test.setTimeout(300_000);
  const { data: manifest } = await svc().from("collection_manifests").select("number").eq("exam_id", exam!.examId).single();
  await signIn(page, admin);
  await page.goto(`/admin/exams/${exam!.examId}`);
  const centre = page.getByTestId("scan-centre");
  await centre.getByRole("textbox", { name: /^Manifest number/ }).fill(manifest!.number);
  await centre.getByRole("button", { name: /^New scan batch/ }).click();
  const batch = centre.getByTestId("scan-batch");
  await expect(batch).toHaveCount(1);
  await expect(batch).toContainText(`B-${exam!.examCode}-01`);
  await expect(batch).toContainText(`Manifest ${manifest!.number}`);
  await batch.locator('input[type="file"]').setInputFiles(files["batch.pdf"]);
  await expect(batch.getByText("Uploaded", { exact: true })).toBeVisible({ timeout: 60_000 });
  await batch.getByRole("button", { name: /^Start processing/ }).click();

  // The processing server reads the file's 11 pages: each copy's five pages, and copy A's page 2 once more.
  const upload = async () => ((await svc().from("script_uploads").select("state").eq("exam_id", exam!.examId)).data ?? []).map((u) => u.state);
  await waitForDb(upload, ["processed"], "the scan file is processed");
  await expect(batch.getByTestId("scan-totals")).toContainText("11 pages: 10 matched, 0 blank, 1 duplicate, 0 to check", { timeout: 30_000 });
  await expect(batch).toContainText("Processed");

  await centre.getByRole("button", { name: /^All scans for this centre are uploaded/ }).click();
  await expect(centre).toContainText("2 candidates: 2 complete.");
  // Scanning records the "scanned" custody step for the batch.
  const { data: steps } = await svc().from("custody_events").select("step").eq("exam_id", exam!.examId).order("seq");
  expect((steps ?? []).map((s) => s.step)).toEqual(["collected", "scanned"]);
  await noSidewaysScroll(page, "the exam page with the scan batch");
});

test("staff_settle_the_duplicate_and_find_both_scripts_verified", async ({ page }) => {
  await signIn(page, admin);
  await page.goto(`/admin/scripts/exceptions?exam=${exam!.examId}`);
  const item = page.getByTestId("exception-list").getByRole("button").filter({ hasText: "Duplicate page" });
  await expect(item).toHaveCount(1);
  await expect(item).toContainText(`Cara${tag} Tester`);
  await item.click();
  const detail = page.getByTestId("exception-detail");
  await expect(detail.getByTestId("exception-found")).toContainText("was scanned more than once. The clearer page was kept and this one set aside.");
  await noSidewaysScroll(page, "the exception queue with a duplicate");
  await detail.locator("label", { hasText: "Keep the page already chosen" }).click();
  await expect(detail.getByRole("radio", { name: "Keep the page already chosen" })).toBeChecked();
  await detail.getByLabel("Reason (kept in the audit log)").fill("The same page was scanned twice.");
  await detail.getByRole("button", { name: "Keep the page already chosen" }).click();
  await expect(page.getByTestId("exception-done")).toContainText("Kept the page already chosen.");

  await waitForDb(() => scriptStates(exam!.examId), { [bookingA]: "verified", [bookingB]: "verified" }, "both scripts are verified");
  await page.goto(`/admin/scripts?exam=${exam!.examId}`);
  const rows = page.getByTestId("script-list").locator("tbody tr");
  await expect(rows).toHaveCount(2);
  for (const name of [`Cara${tag} Tester`, `Dev${tag} Tester`]) {
    const row = rows.filter({ hasText: name });
    await expect(row).toContainText("Verified");
    await expect(row).toContainText("Centre");
  }
  await noSidewaysScroll(page, "the script list");

  await page.goto("/admin");
  const row = page.getByTestId("scripts-exam").filter({ hasText: exam!.title });
  await expect(row.locator("td")).toHaveText(["2", "2", "2", "0", "0"]);
});
