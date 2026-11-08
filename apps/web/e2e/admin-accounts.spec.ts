import { expect, test } from "@playwright/test";
import {
  warmUp,
  assertNoOwner,
  canRead,
  cleanup,
  clearLoginAttempts,
  countTestUsers,
  createAccount,
  createLinkRequest,
  createPendingStudent,
  parentLinked,
  profileByEmail,
  signInUI,
  studentDetails,
  testEmail,
  trackEmail,
} from "./admin";

// Approvals, rejections, parent badge and link requests. Serial (workers: 1); the account-management
// tests live in admin-manage.spec.ts so each file stays inside the hosted Auth sign-in rate-limit window.

test.beforeAll(async () => {
  await assertNoOwner();
  await warmUp();
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterEach(async () => {
  await cleanup();
});
test.afterAll(async () => {
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

type P = import("@playwright/test").Page;
const pendingRow = (page: P, text: string) =>
  page.getByRole("region", { name: /^Pending approvals/ }).getByRole("row").filter({ hasText: text });
const linkRow = (page: P, text: string) =>
  page.getByRole("region", { name: /^Parent link requests/ }).getByRole("row").filter({ hasText: text });

async function openAccounts(page: import("@playwright/test").Page, admin: { email: string; password: string }) {
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/accounts");
}

test("admin_approves_student_and_index_number_shows", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  const parentEmail = testEmail("newparent");
  trackEmail(parentEmail);
  const student = await createPendingStudent({ parentEmail, parentName: "Pat Ding" });
  await openAccounts(page, admin);

  const row = pendingRow(page, student.email);
  await expect(row).toContainText("E2E School");
  await expect(row).toContainText("2009-04-12");
  await expect(row).toContainText(parentEmail);
  await row.getByRole("button", { name: "Approve" }).click();

  const status = page.getByRole("status").filter({ hasText: /SE-\d{4}-\d{4}/ });
  await expect(status).toBeVisible();
  const shown = (await status.textContent())!.match(/SE-\d{4}-\d{4}/)![0];
  expect((await studentDetails(student.id))?.index_number).toBe(shown);
  expect((await profileByEmail(student.email))?.status).toBe("profile_incomplete");
  await expect(pendingRow(page, student.email)).toHaveCount(0);
});

test("admin_rejects_student_and_row_disappears", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  const student = await createPendingStudent({ parentEmail: testEmail("rejparent") });
  await openAccounts(page, admin);

  const row = pendingRow(page, student.email);
  await row.getByRole("button", { name: "Reject" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("Reject and delete this registration? This cannot be undone.");
  await dialog.getByRole("button", { name: "Reject registration" }).click();

  await expect(page.getByText(student.email)).toHaveCount(0);
  expect(await profileByEmail(student.email)).toBeNull();

  // The same email can register again.
  const again = await createPendingStudent({ parentEmail: testEmail("rejparent2"), email: student.email });
  expect(again.id).not.toBe(student.id);
  expect((await profileByEmail(student.email))?.status).toBe("pending");

});

test("parent_registered_child_shows_badge", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  const parent = await createAccount({ role: "parent", firstName: "Pamela" });
  const student = await createPendingStudent({ parentEmail: parent.email, requestedBy: parent.id });
  await openAccounts(page, admin);

  const row = pendingRow(page, student.email);
  await expect(row).toContainText(`Registered by Pamela Tester (${parent.email})`);
});

test("admin_approves_link_request", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  const parent = await createAccount({ role: "parent" });
  const child = await createAccount({ status: "active", indexNumber: `SE-2026-${String(9000 + Math.floor(Math.random() * 999))}` });
  await createLinkRequest(parent.id, child.id);
  expect(await canRead(parent.email, parent.password, child.id)).toBe(false);

  await openAccounts(page, admin);
  const row = linkRow(page, parent.email);
  await expect(row).toContainText(child.indexNumber!);
  await row.getByRole("button", { name: "Approve" }).click();
  await expect(linkRow(page, parent.email)).toHaveCount(0);

  expect(await parentLinked(parent.id, child.id)).toBe(true);
  expect(await canRead(parent.email, parent.password, child.id)).toBe(true);
});

test("parent_email_is_staff_shows_message", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  const teacher = await createAccount({ role: "teacher" });
  const student = await createPendingStudent({ parentEmail: teacher.email });
  await openAccounts(page, admin);

  const row = pendingRow(page, student.email);
  await row.getByRole("button", { name: "Approve" }).click();
  await expect(page.getByRole("alert").filter({ hasText: "The parent email belongs to a staff account" })).toContainText("Edit the parent email first.");
  expect((await profileByEmail(student.email))?.status).toBe("pending");

  // The admin edits the parent email first, then approval works.
  const newParent = testEmail("fixedparent");
  trackEmail(newParent);
  await pendingRow(page, student.email).getByRole("button", { name: "Edit parent email" }).click();
  const dialog = page.getByRole("dialog");
  await dialog.getByLabel("Parent email").fill(newParent);
  await dialog.getByRole("button", { name: "Save" }).click();
  await expect(page.getByRole("status")).toHaveText("Parent email updated.");
  await expect(pendingRow(page, student.email)).toContainText(newParent);
  await pendingRow(page, student.email).getByRole("button", { name: "Approve" }).click();
  await expect(page.getByRole("status").filter({ hasText: /SE-\d{4}-\d{4}/ })).toBeVisible();
});
