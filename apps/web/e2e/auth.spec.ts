import { expect, test, type Page } from "@playwright/test";
import {
  CALLBACK,
  authLinkPath,
  clearLoginAttempts,
  createUnconfirmed,
  assertNoOwner,
  cleanup,
  countTestUsers,
  createAccount,
  createPendingStudent,
  linkFor,
  profileByEmail,
  redirectTarget,
  svc,
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

async function register(page: Page, email: string) {
  await page.goto("/register");
  await page.getByLabel("First name").fill("Reg");
  await page.getByLabel("Last name").fill("Istrant");
  await page.getByLabel("Date of birth").fill("2009-04-12");
  await page.getByLabel("School", { exact: true }).fill("E2E School");
  await page.getByLabel("Parent name").fill("Parent Istrant");
  await page.getByLabel("Parent email").fill(testEmail("parent"));
  await page.getByLabel("Your email").fill(email);
  await page.getByRole("checkbox").check();
  await page.getByRole("button", { name: "Create account" }).click();
}

async function setPasswordFromLink(page: Page, tokenHash: string, password: string) {
  await page.goto(authLinkPath(tokenHash, "recovery"));
  await expect(page).toHaveURL(/\/reset-password\?mode=set/);
  await page.getByLabel("New password", { exact: true }).fill(password);
  await page.getByLabel("Confirm new password").fill(password);
  await page.getByRole("button", { name: "Set password" }).click();
}

// A student confirms through the emailed recovery link (here generated directly, no inbox) and chooses the password.
async function confirmAndSignIn(page: Page, email: string, password: string) {
  const { tokenHash } = await linkFor("recovery", email);
  await setPasswordFromLink(page, tokenHash, password);
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

// The real register-student function runs (its email goes to the console provider, no inbox needed).
test("register_then_confirm_shows_pending", async ({ page }) => {
  const email = testEmail("reg");
  const password = testPassword();
  trackEmail(email);
  await register(page, email);
  await expect(page.getByText("Check your email to confirm your address and choose your password.")).toBeVisible();
  expect((await profileByEmail(email))?.status).toBe("unconfirmed"); // needs a working email provider
  await confirmAndSignIn(page, email, password);
});

test("confirm_link_shows_pending", async ({ page }) => {
  const a = await createUnconfirmed();
  expect((await profileByEmail(a.email))?.status).toBe("unconfirmed");
  await confirmAndSignIn(page, a.email, testPassword());
});

test("register_form_has_no_password_field", async ({ page }) => {
  await page.goto("/register");
  await expect(page.getByLabel("Your email")).toBeVisible();
  await expect(page.getByLabel("Password")).toHaveCount(0);
  await expect(page.locator('input[type="password"]')).toHaveCount(0);
});

test("register_form_sends_signup_metadata", async ({ page }) => {
  // The function call is answered locally so nothing is created; this checks the form wiring only.
  let body: Record<string, string> = {};
  let signUpCalls = 0;
  await page.route("**/auth/v1/signup*", async (route) => {
    signUpCalls++;
    await route.abort();
  });
  await page.route("**/functions/v1/register-student", async (route) => {
    if (route.request().method() === "OPTIONS") return route.fallback();
    body = route.request().postDataJSON();
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      headers: { "access-control-allow-origin": "*" },
      body: JSON.stringify({ ok: true }),
    });
  });
  const email = testEmail("wiring");
  await register(page, email);
  await expect(page.getByText("Check your email to confirm your address and choose your password.")).toBeVisible();
  expect(signUpCalls).toBe(0); // the form no longer uses auth.signUp
  expect(body).toMatchObject({
    firstName: "Reg",
    lastName: "Istrant",
    email,
    dateOfBirth: "2009-04-12",
    school: "E2E School",
    parentName: "Parent Istrant",
  });
  expect(body).not.toHaveProperty("password");
  expect(body).not.toHaveProperty("role");
  expect(body).not.toHaveProperty("status");
});

test("duplicate_email_shows_check_email_screen", async ({ page }) => {
  const existing = await createAccount({ status: "active" });
  await register(page, existing.email);
  // Same neutral screen: never reveals that the address is taken.
  await expect(page.getByText("Check your email to confirm your address and choose your password.")).toBeVisible();
  expect((await profileByEmail(existing.email))?.status).toBe("active");
});

test("register_does_not_replace_a_young_unconfirmed_signup", async ({ page }) => {
  // A sign-up under an hour old keeps its link: a second submitter cannot knock it out.
  const victim = await createUnconfirmed();
  await register(page, victim.email);
  await expect(page.getByText("Check your email to confirm your address and choose your password.")).toBeVisible();
  expect((await profileByEmail(victim.email))?.id).toBe(victim.id);
});

test("pending_screen_shows_the_parent_email_on_record", async ({ page }) => {
  const parentEmail = testEmail("parent");
  const a = await createPendingStudent({ parentEmail });
  await signIn(page, a.email, a.password);
  await expect(page).toHaveURL(/\/account\/pending$/);
  await expect(page.getByText(`Parent email on record: ${parentEmail}`)).toBeVisible();
  await expect(page.getByText("Not right? Contact the institution.")).toBeVisible();
});

test("set_password_shows_a_clear_message_for_weak_passwords", async ({ page }) => {
  const a = await createAccount({ status: "active" });
  const { tokenHash } = await linkFor("recovery", a.email);
  await page.goto(authLinkPath(tokenHash, "recovery"));
  await expect(page).toHaveURL(/\/reset-password\?mode=set/);
  // The answer GoTrue gives when the project rejects weak or leaked passwords (simulated: the setting may be off).
  await page.route("**/auth/v1/user", async (route) => {
    if (route.request().method() !== "PUT") return route.fallback();
    await route.fulfill({
      status: 422,
      contentType: "application/json",
      headers: { "access-control-allow-origin": "*" },
      body: JSON.stringify({
        code: 422,
        error_code: "weak_password",
        msg: "Password is known to be weak and easy to guess, please choose a different one.",
        weak_password: { reasons: ["pwned"] },
      }),
    });
  });
  await page.getByLabel("New password", { exact: true }).fill("password1234");
  await page.getByLabel("Confirm new password").fill("password1234");
  await page.getByRole("button", { name: "Set password" }).click();
  await expect(page.locator("p[role=alert]")).toHaveText(
    "Choose a stronger password \u2014 this one is too common or has appeared in a data breach.",
  );
  // Over 72 characters is refused with clear text before anything is sent.
  const long = "a1".repeat(40);
  await page.getByLabel("New password", { exact: true }).fill(long);
  await page.getByLabel("Confirm new password").fill(long);
  await page.getByRole("button", { name: "Set password" }).click();
  await expect(page.locator("p[role=alert]")).toHaveText("Use 72 characters or fewer.");
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
  // The recover request is answered locally so no real email is sent.
  const recoverBodies: Array<{ email?: string }> = [];
  await page.route("**/auth/v1/recover*", async (route) => {
    recoverBodies.push(route.request().postDataJSON());
    await route.fulfill({ status: 200, contentType: "application/json", body: "{}" });
  });
  await page.goto("/reset-password");
  await page.getByLabel("Email").fill(a.email);
  await page.getByRole("button", { name: "Send reset link" }).click();
  await expect(page.getByText("If an account exists for that address")).toBeVisible();
  expect(recoverBodies).toHaveLength(1);
  expect(recoverBodies[0].email).toBe(a.email);
  // Stand-in for the emailed link: a recovery link for the same user, in the format the emails use.
  const { tokenHash } = await linkFor("recovery", a.email);
  await page.goto(authLinkPath(tokenHash, "recovery"));
  await expect(page).toHaveURL(/\/reset-password\?mode=set/);
  const next = testPassword();
  await page.getByLabel("New password", { exact: true }).fill(next);
  await page.getByLabel("Confirm new password").fill(next);
  await page.getByRole("button", { name: "Set password" }).click();
  await expect(page).toHaveURL(/\/account\/home$/);
});

test("invited_tutor_sets_password_from_emailed_link", async ({ page }) => {
  const tutor = await createAccount({ role: "tutor" });
  // Same link shape invite-user emails (recovery token_hash via the callback).
  const { tokenHash } = await linkFor("recovery", tutor.email);
  await page.goto(authLinkPath(tokenHash, "recovery"));
  await expect(page).toHaveURL(/\/reset-password\?mode=set/);
  const next = testPassword();
  await page.getByLabel("New password", { exact: true }).fill(next);
  await page.getByLabel("Confirm new password").fill(next);
  await page.getByRole("button", { name: "Set password" }).click();
  await expect(page).toHaveURL(/\/tutor$/);
  await page.context().clearCookies();
  await signIn(page, tutor.email, next);
  await expect(page).toHaveURL(/\/tutor$/);
});

test("parent_registered_child_sets_password_from_emailed_link", async ({ page }) => {
  // parent-child register leaves the child exactly like this (unconfirmed, no usable password).
  const child = await createUnconfirmed();
  const { tokenHash } = await linkFor("recovery", child.email);
  await page.goto(authLinkPath(tokenHash, "recovery"));
  await expect(page).toHaveURL(/\/reset-password\?mode=set/);
  const next = testPassword();
  await page.getByLabel("New password", { exact: true }).fill(next);
  await page.getByLabel("Confirm new password").fill(next);
  await page.getByRole("button", { name: "Set password" }).click();
  await expect(page).toHaveURL(/\/account\/pending$/);
  expect((await profileByEmail(child.email))?.status).toBe("pending");
  await page.context().clearCookies();
  await signIn(page, child.email, next);
  await expect(page).toHaveURL(/\/account\/pending$/);
});

test("admin_can_open_admin_but_not_owner", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  await signIn(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/accounts");
  await expect(page).toHaveURL(/\/admin\/accounts$/);
  await page.goto("/owner");
  await expect(page).toHaveURL(/\/admin$/);
});

test("owner_can_open_owner_and_admin", async ({ page }) => {
  const owner = await createAccount({ role: "owner" });
  try {
    await signIn(page, owner.email, owner.password);
    await expect(page).toHaveURL(/\/owner$/);
    await page.goto("/admin");
    await expect(page).toHaveURL(/\/admin$/);
    await page.goto("/owner");
    await expect(page).toHaveURL(/\/owner$/);
  } finally {
    // Delete the owner immediately so an aborted run cannot leave one on dev.
    await svc().auth.admin.deleteUser(owner.id);
  }
});

test("recovery_token_with_edited_type_still_requires_new_password", async ({ page }) => {
  const a = await createAccount({ status: "active" });
  const { tokenHash } = await linkFor("recovery", a.email);
  await page.goto(`/auth/callback?token_hash=${encodeURIComponent(tokenHash)}&type=email`);
  // GoTrue accepts the mismatched type (and signs the session "otp"), so the callback must still force set-password.
  await expect(page).toHaveURL(/\/reset-password\?mode=set/);
});

test("student_redirected_from_every_staff_area", async ({ page }) => {
  const a = await createAccount({ status: "active" });
  await signIn(page, a.email, a.password);
  await expect(page).toHaveURL(/\/account\/home$/);
  for (const area of ["/owner", "/teacher", "/tutor", "/corrector", "/admin"]) {
    await page.goto(area);
    await expect(page, area).toHaveURL(/\/account\/home$/);
  }
});

test("signed_out_account_page_goes_to_login", async ({ page }) => {
  await page.goto("/account/home");
  await expect(page).toHaveURL(/\/login/);
});

test("suspended_staff_cannot_reach_admin", async ({ page }) => {
  const admin = await createAccount({ role: "admin", status: "suspended" });
  await signIn(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/account\/suspended$/);
  await page.goto("/admin");
  await expect(page).toHaveURL(/\/account\/suspended$/);
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

test("banned_account_gets_the_wrong_password_message", async ({ page }) => {
  const a = await createAccount({ role: "teacher" });
  const { error } = await svc().auth.admin.updateUserById(a.id, { ban_duration: "876000h" });
  expect(error).toBeNull();
  await signIn(page, a.email, a.password);
  await expect(page.getByText("Email or password is incorrect.")).toBeVisible();
});

test("delete_my_account_confirm_then_signed_out", async ({ page }) => {
  const a = await createAccount({ status: "active" });
  await signIn(page, a.email, a.password);
  await expect(page).toHaveURL(/\/account\/home$/);

  // Cancel keeps the account.
  await page.getByRole("button", { name: "Delete my account" }).click();
  const dialog = page.getByRole("dialog", { name: "Delete my account" });
  await expect(dialog.getByText("Permanently delete your account and data? This cannot be undone.")).toBeVisible();
  await dialog.getByRole("button", { name: "Cancel" }).click();
  await expect(dialog).toHaveCount(0);
  expect(await profileByEmail(a.email)).not.toBeNull();

  // Confirm deletes it and lands on the sign-in page with a notice.
  await page.getByRole("button", { name: "Delete my account" }).click();
  await page.getByRole("dialog", { name: "Delete my account" }).getByRole("button", { name: "Delete my account" }).click();
  await expect(page).toHaveURL(/\/login\?notice=deleted$/);
  await expect(page.getByText("Your account and data have been deleted.")).toBeVisible();
  expect(await profileByEmail(a.email)).toBeNull();
  await signIn(page, a.email, a.password);
  await expect(page.getByText("Email or password is incorrect.")).toBeVisible();
});

test("delete_my_account_is_offered_on_the_pending_page", async ({ page }) => {
  const b = await createAccount({ status: "pending" });
  await signIn(page, b.email, b.password);
  await expect(page).toHaveURL(/\/account\/pending$/);
  await expect(page.getByRole("button", { name: "Delete my account" })).toBeVisible();
});

test("papers_read_api_needs_a_staff_session", async ({ page, request }) => {
  const pdf = { name: "x.pdf", mimeType: "application/pdf", buffer: Buffer.from("%PDF-1.4") };
  const anonymous = await request.post("/api/papers/read", { multipart: { file: pdf } });
  expect(anonymous.status()).toBe(401);

  const student = await createAccount({ status: "active" });
  await signIn(page, student.email, student.password);
  await expect(page).toHaveURL(/\/account\/home$/);
  const asStudent = await page.request.post("/api/papers/read", { multipart: { file: pdf } });
  expect(asStudent.status()).toBe(403);

  const admin = await createAccount({ role: "admin", status: "active" });
  const ctx = await page.context().browser()!.newContext({ baseURL: "http://localhost:3005" });
  const p2 = await ctx.newPage();
  await signIn(p2, admin.email, admin.password);
  await expect(p2).toHaveURL(/\/admin/);
  const asAdmin = await p2.request.post("/api/papers/read", { multipart: { file: pdf } });
  expect([200, 422]).toContain(asAdmin.status()); // authorised; a stub PDF may not be readable
  await ctx.close();
});
