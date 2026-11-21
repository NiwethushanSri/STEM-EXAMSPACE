import { expect, test, type Page } from "@playwright/test";
import { assertNoOwner, cleanup, clearLoginAttempts, countTestUsers, createAccount, signInUI, svc, type TestAccount } from "./admin";
import { CODE_A, CODE_B, noSidewaysScroll, removeExam, requireProcessor, scriptFiles, seedCandidate, seedExam, waitForDb, type SeededExam } from "./scripts";

// A home sitting end to end (Phase 2): a parent confirms supervision, hands in phone photos of their child's copy A
// (and, by mistake, a photo of copy B's page 2, printed for another candidate), sees "Checking your pages" while the
// real processing server reads them, then "Received" and the receipt. Staff find copy B's page in the exception
// queue and the exam's figures on the admin dashboard. Needs the processing server (npm run e2e:local starts it).
// Serial: the tests build on one hand-in. Every row and file it makes is removed again.

test.describe.configure({ mode: "serial" });

const tag = crypto.randomUUID().slice(0, 8);
// The two candidates' index numbers come from separate ranges, so they never clash.
const indexStudent = `SE-2026-${7000 + Math.floor(Math.random() * 499)}`;
const indexOther = `SE-2026-${7500 + Math.floor(Math.random() * 499)}`;

let admin: TestAccount;
let parent: TestAccount;
let student: TestAccount;
let other: TestAccount;
let exam: SeededExam | undefined;
let booking: string;
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
  admin = await createAccount({ role: "admin" });
  parent = await createAccount({ role: "parent", firstName: `Pat${tag}` });
  student = await createAccount({ status: "active", firstName: `Hana${tag}`, indexNumber: indexStudent });
  other = await createAccount({ status: "active", firstName: `Omar${tag}`, indexNumber: indexOther });
  const link = await svc().from("parent_children").insert({ parent_id: parent.id, student_id: student.id });
  if (link.error) throw new Error(`parent link failed: ${link.error.message}`);
  // Started 10 minutes ago, 90 minutes long: the sitting is on, so the parent can still confirm and hand in.
  exam = await seedExam({ tag, title: "Home scripts", sitting: "home", startedMinutesAgo: 10, adminId: admin.id });
  booking = await seedCandidate(exam, student.id, CODE_A, { bookedBy: parent.id, adminId: admin.id });
  await seedCandidate(exam, other.id, CODE_B, { adminId: admin.id });
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterAll(async () => {
  await removeExam(exam);
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

test("parent_confirms_hands_in_photos_and_gets_the_receipt", async ({ page }) => {
  test.setTimeout(300_000);
  await signIn(page, parent);
  await page.goto("/account/bookings");
  const panel = page.getByTestId("sitting-panel");
  await panel.getByRole("button", { name: /^I will supervise this exam at home and follow the rules/ }).click();
  await expect(panel.getByTestId("sitting-ack")).toContainText(`Supervision confirmed by Pat${tag} Tester`);

  await panel.getByTestId("upload-drop").locator('input[type="file"]').setInputFiles([
    files["a-1.jpg"],
    files["a-2.jpg"],
    files["a-3.jpg"],
    files["a-4.jpg"],
    files["a-5.jpg"],
    files["b-2.jpg"],
  ]);
  await expect(panel.getByTestId("upload-files").getByText("Uploaded", { exact: true })).toHaveCount(6, { timeout: 120_000 });
  await noSidewaysScroll(page, "the upload with six photos");
  await panel.getByRole("button", { name: /^Submit/ }).click();
  await expect(panel.getByTestId("upload-status-word")).toHaveText("Checking your pages");

  // The processing server reads the six photos; the hand-in is received once every one is recorded.
  const states = async () => ((await svc().from("home_submissions").select("state").eq("booking_id", booking).order("seq")).data ?? []).map((s) => s.state);
  await waitForDb(states, ["received"], "the hand-in is received");
  await expect(panel.getByTestId("upload-status-word")).toHaveText("Received", { timeout: 30_000 });
  const receipt = panel.getByTestId("upload-receipt");
  await expect(receipt.getByRole("heading", { name: "We have received your answers" })).toBeVisible();
  await expect(receipt.getByTestId("receipt-script")).toHaveText(`S-${exam!.examCode}-0001`);

  // Copy A's five pages are the script; copy B's page is never in it. It waits for staff, so the script needs
  // attention on the staff side while the family has their receipt.
  const { data: script } = await svc().from("scripts").select("id, state, version").eq("booking_id", booking).single();
  expect(script?.state).toBe("needs_attention");
  const { data: links } = await svc().from("script_page_links").select("copy_page").eq("script_id", script!.id).eq("version", script!.version);
  expect((links ?? []).map((l) => l.copy_page).sort()).toEqual([1, 2, 3, 4, 5]);
  await noSidewaysScroll(page, "My bookings with the receipt");
});

test("staff_find_the_other_candidates_page_in_the_exception_queue", async ({ page }) => {
  await signIn(page, admin);
  await page.goto(`/admin/scripts/exceptions?exam=${exam!.examId}`);
  const list = page.getByTestId("exception-list");
  await expect(list.getByRole("button")).toHaveCount(1);
  await expect(list.getByRole("button")).toContainText("Unexpected page");
  await expect(list.getByRole("button")).toContainText("page 2");
  await expect(page.getByTestId("exception-found")).toContainText(
    "This page was printed for another candidate's copy, but it was handed in with this family's answers.",
  );
  await noSidewaysScroll(page, "the exception queue");

  // The admin dashboard counts the exam: two expected (the other candidate has not handed in), one received, which
  // needs attention.
  await page.goto("/admin");
  const row = page.getByTestId("scripts-exam").filter({ hasText: exam!.title });
  await expect(row.locator("td")).toHaveText(["2", "1", "0", "1", "0"]);
  await expect(page.getByTestId("tile-open-exceptions")).not.toHaveText("0");
  await noSidewaysScroll(page, "the admin dashboard");

  // Staff set the page aside; the family's script is then verified.
  await page.goto(`/admin/scripts/exceptions?exam=${exam!.examId}`);
  const detail = page.getByTestId("exception-detail");
  await detail.locator("label", { hasText: "Mark as blank" }).click();
  await expect(detail.getByRole("radio", { name: "Mark as blank" })).toBeChecked();
  await detail.getByLabel(/^Reason/).fill("Another candidate's page, handed in by mistake.");
  await detail.getByRole("button", { name: "Mark as blank" }).click();
  await expect(page.getByTestId("exception-done")).toContainText("Marked as blank. The page is set aside.");
  await waitForDb(async () => (await svc().from("scripts").select("state").eq("booking_id", booking).single()).data?.state, "verified", "the script is verified");
  await page.goto("/admin");
  await expect(page.getByTestId("scripts-exam").filter({ hasText: exam!.title }).locator("td")).toHaveText(["2", "1", "1", "0", "0"]);
});
