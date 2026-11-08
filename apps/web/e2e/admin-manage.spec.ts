import { expect, test } from "@playwright/test";
import {
  assertNoOwner,
  cleanup,
  clearLoginAttempts,
  countTestUsers,
  createAccount,
  profileByEmail,
  signInUI,
  testEmail,
  trackEmail,
} from "./admin";

// Account management by role. Serial; see admin-accounts.spec.ts for the approval flows.

test.beforeAll(async () => {
  await assertNoOwner();
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

async function filterTo(page: import("@playwright/test").Page, text: string) {
  await page.getByLabel("Search accounts").fill(text);
}

test("admin_invite_dialog_has_no_admin_option", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/accounts");
  await page.getByRole("button", { name: "Invite staff" }).click();
  const options = await page.getByRole("dialog").getByLabel("Role").locator("option").allTextContents();
  expect(options).toEqual(["Teacher", "Tutor", "Exam corrector"]);
});

test("owner_can_invite_admin", async ({ page }) => {
  const owner = await createAccount({ role: "owner" });
  const inviteeEmail = testEmail("newadmin");
  trackEmail(inviteeEmail);
  try {
    await signInUI(page, owner.email, owner.password);
    await expect(page).toHaveURL(/\/owner$/);
    await expect(page.getByRole("heading", { name: "Super administrator" })).toBeVisible();
    await page.goto("/owner/staff");
    await page.getByRole("button", { name: "Invite staff" }).click();
    const dialog = page.getByRole("dialog");
    expect(await dialog.getByLabel("Role").locator("option").allTextContents()).toContain("Admin");
    await dialog.getByLabel("Email").fill(inviteeEmail);
    await dialog.getByLabel("First name").fill("Nova");
    await dialog.getByLabel("Last name").fill("Admin");
    await dialog.getByLabel("Role").selectOption("admin");
    await dialog.getByRole("button", { name: "Send invitation" }).click();
    await expect(page.getByRole("status")).toContainText("Invitation");
    await expect.poll(async () => (await profileByEmail(inviteeEmail))?.role).toBe("admin");
  } finally {
    await cleanup();
  }
  await assertNoOwner();
});

test("admin_cannot_see_actions_on_admin", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  const other = await createAccount({ role: "admin" });
  const tutor = await createAccount({ role: "tutor" });
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/accounts");

  await filterTo(page, other.email);
  const otherRow = page.getByRole("region", { name: /^All accounts/ }).getByRole("row").filter({ hasText: other.email });
  await expect(otherRow).toBeVisible();
  await expect(otherRow.getByRole("button")).toHaveCount(0);

  await filterTo(page, admin.email);
  await expect(page.getByRole("region", { name: /^All accounts/ }).getByRole("row").filter({ hasText: admin.email }).getByRole("button")).toHaveCount(0);

  await filterTo(page, tutor.email);
  await expect(page.getByRole("region", { name: /^All accounts/ }).getByRole("row").filter({ hasText: tutor.email }).getByRole("button", { name: "Suspend" })).toBeVisible();
});

test("suspend_then_reactivate_tutor", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  const tutor = await createAccount({ role: "tutor" });
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/accounts");
  await filterTo(page, tutor.email);

  const row = () => page.getByRole("region", { name: /^All accounts/ }).getByRole("row").filter({ hasText: tutor.email });
  await row().getByRole("button", { name: "Suspend" }).click();
  await expect(row().getByRole("button", { name: "Reactivate" })).toBeVisible();
  expect((await profileByEmail(tutor.email))?.status).toBe("suspended");

  await row().getByRole("button", { name: "Reactivate" }).click();
  await expect(row().getByRole("button", { name: "Suspend" })).toBeVisible();
  expect((await profileByEmail(tutor.email))?.status).toBe("active");
});

test("delete_account_student", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  const student = await createAccount({ status: "active" });
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/accounts");
  await filterTo(page, student.email);

  await page.getByRole("region", { name: /^All accounts/ }).getByRole("row").filter({ hasText: student.email }).getByRole("button", { name: "Delete account" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("Permanently delete this account and its data?");
  await dialog.getByRole("button", { name: "Delete account" }).click();
  await expect(page.getByText(student.email)).toHaveCount(0);
  expect(await profileByEmail(student.email)).toBeNull();
});

test("mock_student_page_redirects", async ({ page }) => {
  await page.goto("/student");
  await expect(page).toHaveURL(/\/login/);
  await page.goto("/parent/results");
  await expect(page).toHaveURL(/\/login/);

  const admin = await createAccount({ role: "admin" });
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/student/results");
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/examiner");
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/exams");
  await expect(page.getByText("Preview — sample data")).toBeVisible();
});
