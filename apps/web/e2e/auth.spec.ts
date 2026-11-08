import { expect, test, type Page } from "@playwright/test";
import {
  CALLBACK,
  clearLoginAttempts,
  HAS_INBOX_DOMAIN,
  createUnconfirmed,
  assertNoOwner,
  cleanup,
  countTestUsers,
  createAccount,
  linkFor,
  profileByEmail,
  redirectTarget,
  testEmail,
  testPassword,
  trackEmail,
} from "./admin";

// Tests are independent; workers: 1 in the config runs them one at a time.

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

async function signIn(page: Page, identifier: string, password: string) {
  await page.goto("/login");
  await page.getByLabel("Email or index number").fill(identifier);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in" }).click();
}

async function register(page: Page, email: string, password: string) {
  await page.goto("/register");
  await page.getByLabel("First name").fill("Reg");
  await page.getByLabel("Last name").fill("Istrant");
  await page.getByLabel("Date of birth").fill("2009-04-12");
  await page.getByLabel("School", { exact: true }).fill("E2E School");
  await page.getByLabel("Parent name").fill("Parent Istrant");
  await page.getByLabel("Parent email").fill(testEmail("parent"));
  await page.getByLabel("Your email").fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("checkbox").check();
  await page.getByRole("button", { name: "Create account" }).click();
}

async function confirmAndSignIn(page: Page, email: string, password: string) {
  // Confirm via an admin-generated link (no inbox), landing on the real callback route.
  const { tokenHash } = await linkFor("magiclink", email);
  await page.goto(`/auth/callback?token_hash=${tokenHash}&type=email`);
  await expect(page).toHaveURL(/\/account\/pending$/);
  await expect(page.getByText("Awaiting approval").first()).toBeVisible();
  expect((await profileByEmail(email))?.status).toBe("pending");

  await page.getByRole("button", { name: "Sign out" }).click();
  await expect(page).toHaveURL(/\/login/);
  await signIn(page, email, password);
  await expect(page).toHaveURL(/\/account\/pending$/);
}

test("generated auth links redirect to the local callback", async () => {
  const a = await createAccount({ status: "active" });
  const { actionLink } = await linkFor("recovery", a.email);
  const target = await redirectTarget(actionLink);
  expect(target ?? "", `GoTrue redirected to: ${target}`).toContain(CALLBACK);
});

// Needs a sign-up domain GoTrue accepts plus custom SMTP (the built-in mailer allows a handful of emails
// per hour and rejects reserved domains): set TEST_INBOX_DOMAIN in .env.dev.local to run it.
test("register_then_confirm_shows_pending", async ({ page }) => {
  test.skip(!HAS_INBOX_DOMAIN, "requires TEST_INBOX_DOMAIN (custom SMTP on the dev project)");
  const email = testEmail("reg");
  const password = testPassword();
  trackEmail(email);
  await register(page, email, password);
  await expect(page.getByText("Check your email to confirm your address")).toBeVisible();
  expect((await profileByEmail(email))?.status).toBe("unconfirmed");
  await confirmAndSignIn(page, email, password);
});

test("confirm_link_shows_pending", async ({ page }) => {
  const a = await createUnconfirmed();
  expect((await profileByEmail(a.email))?.status).toBe("unconfirmed");
  await confirmAndSignIn(page, a.email, a.password);
});

test("register_form_sends_signup_metadata", async ({ page }) => {
  // The sign-up request is answered locally so no email is sent; this checks the form wiring only.
  let body: { email?: string; data?: Record<string, string> } = {};
  await page.route("**/auth/v1/signup*", async (route) => {
    body = route.request().postDataJSON();
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ id: crypto.randomUUID(), aud: "authenticated", email: body.email, identities: [{ id: "x" }] }),
    });
  });
  const email = testEmail("wiring");
  await register(page, email, testPassword());
  await expect(page.getByText("Check your email to confirm your address")).toBeVisible();
  expect(body.email).toBe(email);
  expect(body.data).toMatchObject({
    first_name: "Reg",
    last_name: "Istrant",
    date_of_birth: "2009-04-12",
    school: "E2E School",
    parent_name: "Parent Istrant",
  });
  expect(body.data).not.toHaveProperty("role");
  expect(body.data).not.toHaveProperty("status");
});

test("duplicate_email_shows_check_email_screen", async ({ page }) => {
  const existing = await createAccount({ status: "active" });
  await register(page, existing.email, testPassword());
  // Same neutral screen: never reveals that the address is taken.
  await expect(page.getByText("Check your email to confirm your address")).toBeVisible();
  expect((await profileByEmail(existing.email))?.status).toBe("active");
});

test("student_cannot_open_admin", async ({ page }) => {
  const a = await createAccount({ status: "active" });
  await page.goto("/admin");
  await expect(page).toHaveURL(/\/login/);
  await signIn(page, a.email, a.password);
  await expect(page).toHaveURL(/\/account\/home$/);
  await page.goto("/admin");
  await expect(page).toHaveURL(/\/account\/home$/);
  await page.goto("/admin/accounts");
  await expect(page).toHaveURL(/\/account\/home$/);
});

test("wrong_password_shows_generic_error", async ({ page }) => {
  const a = await createAccount({ status: "active" });
  await signIn(page, a.email, "definitely-wrong-1");
  await expect(page.getByText("Email or password is incorrect.")).toBeVisible();
  // An unknown email gets the very same message.
  await signIn(page, testEmail("nobody"), "definitely-wrong-1");
  await expect(page.getByText("Email or password is incorrect.")).toBeVisible();
  await signIn(page, "SE-2026-9999", "definitely-wrong-1");
  await expect(page.getByText("Index number or password is incorrect.")).toBeVisible();
});

test("index_number_login_works", async ({ page }) => {
  const index = `SE-2026-9${String(Math.floor(Math.random() * 1000)).padStart(3, "0")}`;
  const a = await createAccount({ status: "active", indexNumber: index, firstName: "Indy" });
  await signIn(page, ` ${index.toLowerCase().replace(/-/g, " ")} `, a.password);
  await expect(page).toHaveURL(/\/account\/home$/);
  await expect(page.getByText("Your dashboard is coming soon")).toBeVisible();
  await expect(page.getByText(index)).toBeVisible();
  await expect(page.getByText("Indy").first()).toBeVisible();
});

test("profile_completion_activates", async ({ page }) => {
  const a = await createAccount({ status: "profile_incomplete" });
  await signIn(page, a.email, a.password);
  await expect(page).toHaveURL(/\/account\/profile\/complete$/);
  // A non-JPEG photo is rejected client-side.
  await page.getByLabel("Photo").setInputFiles({ name: "x.png", mimeType: "image/png", buffer: Buffer.from("png") });
  await expect(page.getByText("Photo must be a JPEG under 5 MB")).toBeVisible();
  await page.getByLabel("Gender").selectOption("Female");
  await page.getByLabel("Year group").selectOption("Year 12");
  await page.locator("label", { hasText: /^Maths$/ }).click();
  await expect(page.getByRole("checkbox", { name: "Maths", exact: true })).toBeChecked();
  await page.getByLabel("Parent phone").fill("07700 900123");
  await page.getByRole("button", { name: "Save and continue" }).click();
  await expect(page).toHaveURL(/\/account\/home$/);
  expect((await profileByEmail(a.email))?.status).toBe("active");
});

test("reset_password_sets_new_password", async ({ page }) => {
  const a = await createAccount({ status: "active" });
  const { tokenHash } = await linkFor("recovery", a.email);
  await page.goto(`/auth/callback?token_hash=${tokenHash}&type=recovery`);
  await expect(page).toHaveURL(/\/reset-password\?mode=set/);
  const next = testPassword();
  await page.getByLabel("New password", { exact: true }).fill(next);
  await page.getByLabel("Confirm new password").fill(next);
  await page.getByRole("button", { name: "Set password" }).click();
  await expect(page).toHaveURL(/\/account\/home$/);
  await page.getByRole("button", { name: "Sign out" }).click();
  await signIn(page, a.email, a.password);
  await expect(page.getByText("Email or password is incorrect.")).toBeVisible();
  await signIn(page, a.email, next);
  await expect(page).toHaveURL(/\/account\/home$/);
});

test("recovery_after_forgot_password_request", async ({ page }) => {
  const a = await createAccount({ status: "active" });
  // Real request from the UI (the email is captured by the sandbox SMTP; the inbox is not read).
  await page.goto("/reset-password");
  await page.getByLabel("Email").fill(a.email);
  await page.getByRole("button", { name: "Send reset link" }).click();
  await expect(page.getByText("If an account exists for that address")).toBeVisible();
  // Stand-in for the emailed link: an admin-generated recovery link for the same user.
  const { tokenHash } = await linkFor("recovery", a.email);
  await page.goto(`/auth/callback?token_hash=${tokenHash}&type=recovery`);
  await expect(page).toHaveURL(/\/reset-password\?mode=set/);
  const next = testPassword();
  await page.getByLabel("New password", { exact: true }).fill(next);
  await page.getByLabel("Confirm new password").fill(next);
  await page.getByRole("button", { name: "Set password" }).click();
  await expect(page).toHaveURL(/\/account\/home$/);
});

test("reset_request_is_neutral", async ({ page }) => {
  await page.goto("/reset-password");
  await page.getByLabel("Email").fill(testEmail("ghost"));
  await page.getByRole("button", { name: "Send reset link" }).click();
  await expect(page.getByText("If an account exists for that address")).toBeVisible();
});

test("suspended_student_sees_suspended_screen", async ({ page }) => {
  const a = await createAccount({ status: "suspended" });
  await signIn(page, a.email, a.password);
  await expect(page).toHaveURL(/\/account\/suspended$/);
  await expect(page.getByText("Your account is suspended, contact the institution")).toBeVisible();
});
