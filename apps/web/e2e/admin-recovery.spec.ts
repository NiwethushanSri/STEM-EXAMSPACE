import { expect, test, type Page } from "@playwright/test";
import {
  warmUp,
  approveDirectly,
  assertNoOwner,
  cleanup,
  clearLoginAttempts,
  countTestUsers,
  createAccount,
  createPendingStudent,
  createStuckInvite,
  inviteCount,
  parentLinked,
  profileByEmail,
  removeInvite,
  signInUI,
  testEmail,
  trackEmail,
} from "./admin";

// Recovery flows and the server-side guards. Serial; a separate file keeps each file inside the Auth window.

let stuckEmail: string | null = null;

test.beforeAll(async () => {
  await assertNoOwner();
  await warmUp();
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterEach(async () => {
  if (stuckEmail) await removeInvite(stuckEmail);
  stuckEmail = null;
  await cleanup();
});
test.afterAll(async () => {
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

const allAccounts = (page: Page) => page.getByRole("region", { name: /^All accounts/ });

async function search(page: Page, text: string) {
  await page.getByLabel("Search accounts").fill(text);
  await page.getByLabel("Search accounts").press("Enter");
  await expect(page).toHaveURL(/q=/);
}

test("resend_parent_invite_for_approved_unlinked_student", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  const parentEmail = testEmail("lateparent");
  trackEmail(parentEmail);
  const student = await createPendingStudent({ parentEmail, parentName: "Lena Late" });
  await approveDirectly(student.id, `SE-2096-${String(1000 + Math.floor(Math.random() * 8000))}`);

  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/accounts");
  await search(page, student.email);
  await allAccounts(page).getByRole("row").filter({ hasText: student.email }).getByRole("button", { name: "Resend parent invite" }).click();
  await expect(page.getByRole("status")).toContainText(/Parent (invited and linked|account created and linked)/);

  const parent = await profileByEmail(parentEmail);
  expect(parent?.role).toBe("parent");
  expect(await parentLinked(parent!.id, student.id)).toBe(true);
  // Linked now: the action is gone.
  await expect(allAccounts(page).getByRole("row").filter({ hasText: student.email }).getByRole("button", { name: "Resend parent invite" })).toHaveCount(0);
});

test("clear_stuck_invite_flow", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  stuckEmail = testEmail("stuck");
  trackEmail(stuckEmail);
  await createStuckInvite(stuckEmail);
  expect(await inviteCount(stuckEmail)).toBe(1);

  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/accounts");
  await page.getByText("Troubleshooting").click();
  await page.getByLabel("Clear stuck invite for email").fill(stuckEmail);
  await page.getByRole("button", { name: "Clear invite" }).click();
  await expect(page.getByRole("status")).toHaveText("Stuck invite cleared.");
  expect(await inviteCount(stuckEmail)).toBe(0);
  expect(await profileByEmail(stuckEmail)).toBeNull();
});

test("owner_removes_admin", async ({ page }) => {
  const owner = await createAccount({ role: "owner" });
  const admin = await createAccount({ role: "admin" });
  try {
    await signInUI(page, owner.email, owner.password);
    await expect(page).toHaveURL(/\/owner$/);
    await page.goto("/owner/staff");
    await search(page, admin.email);
    await page.getByRole("region", { name: /^Staff accounts/ }).getByRole("row").filter({ hasText: admin.email }).getByRole("button", { name: "Remove" }).click();
    await page.getByRole("dialog").getByRole("button", { name: "Remove" }).click();
    await expect(page.getByRole("status")).toHaveText("Staff account removed.");
    expect(await profileByEmail(admin.email)).toBeNull();
  } finally {
    await cleanup();
  }
  await assertNoOwner();
  await warmUp();
});

test("owner_pages_refuse_admin", async ({ page }) => {
  const admin = await createAccount({ role: "admin" });
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  for (const path of ["/owner", "/owner/accounts", "/owner/staff"]) {
    await page.goto(path);
    await expect(page).toHaveURL(/\/admin$/);
  }
});

test("student_cannot_invoke_admin_server_action", async ({ page, browser, baseURL }) => {
  const admin = await createAccount({ role: "admin" });
  const t1 = await createAccount({ role: "tutor" });
  const t2 = await createAccount({ role: "tutor" });
  const student = await createAccount({ status: "active" });

  // As admin, capture a real server action call (suspend t1) to learn the action id and payload shape.
  let actionId = "";
  let body = "";
  page.on("request", (r) => {
    const id = r.headers()["next-action"];
    if (id && r.method() === "POST" && r.postData()?.includes(t1.id)) {
      actionId = id;
      body = r.postData()!;
    }
  });
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/accounts");
  await search(page, t1.email);
  await allAccounts(page).getByRole("row").filter({ hasText: t1.email }).getByRole("button", { name: "Suspend" }).click();
  await expect(page.getByRole("status")).toHaveText("Account suspended.");
  expect(actionId).not.toBe("");

  // As a signed-in student, replay that action against t2.
  const ctx = await browser.newContext({ baseURL });
  try {
    const sp = await ctx.newPage();
    await signInUI(sp, student.email, student.password);
    await expect(sp).toHaveURL(/\/account\/home$/);
    // The action is only reachable through the admin routes, which the proxy refuses for a student
    // before any action code runs (the action also re-checks the role itself; see actions.ts).
    const res = await ctx.request.post("/admin/accounts", {
      headers: { "Next-Action": actionId, Accept: "text/x-component", "Content-Type": "text/plain;charset=UTF-8" },
      data: body.replaceAll(t1.id, t2.id),
      maxRedirects: 0,
    });
    expect(res.status()).toBe(307);
    expect(res.headers().location).toContain("/account/home");
    expect((await profileByEmail(t2.email))?.status).toBe("active");
  } finally {
    await ctx.close();
  }
});

test("student_cannot_invoke_admin_action_from_any_route", async ({ page, browser, baseURL }) => {
  const admin = await createAccount({ role: "admin" });
  const t1 = await createAccount({ role: "tutor" });
  const t2 = await createAccount({ role: "tutor" });
  const student = await createAccount({ status: "active" });

  // As admin, capture a real server action call (suspend t1) to learn the action id and payload shape.
  let actionId = "";
  let body = "";
  page.on("request", (r) => {
    const id = r.headers()["next-action"];
    if (id && r.method() === "POST" && r.postData()?.includes(t1.id)) {
      actionId = id;
      body = r.postData()!;
    }
  });
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
  await page.goto("/admin/accounts");
  await search(page, t1.email);
  await allAccounts(page).getByRole("row").filter({ hasText: t1.email }).getByRole("button", { name: "Suspend" }).click();
  await expect(page.getByRole("status")).toHaveText("Account suspended.");
  expect(actionId).not.toBe("");

  // As a signed-in student, replay that action against t2.
  const ctx = await browser.newContext({ baseURL });
  try {
    const sp = await ctx.newPage();
    await signInUI(sp, student.email, student.password);
    await expect(sp).toHaveURL(/\/account\/home$/);
    // Server actions can be POSTed from any route (Next data-security docs): replay the captured accountAction
    // id from a signed-in student against t2. Either the action refuses (forbidden) or the route does not
    // know the id; in no case may it succeed.
    const res = await ctx.request.post("/account/home", {
      headers: { "Next-Action": actionId, Accept: "text/x-component", "Content-Type": "text/plain;charset=UTF-8" },
      data: body.replaceAll(t1.id, t2.id),
      maxRedirects: 0,
    });
    const text = await res.text();
    expect(text).not.toContain("Account suspended.");
    expect(text).not.toMatch(/"ok":\s*true/);
    expect(text === "{}" || /forbidden|You do not have permission|"ok":\s*false/.test(text), `unexpected response: ${text.slice(0, 200)}`).toBe(true);
    expect((await profileByEmail(t2.email))?.status).toBe("active");
  } finally {
    await ctx.close();
  }
});
