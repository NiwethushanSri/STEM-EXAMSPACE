import { expect, test, type Page } from "@playwright/test";
import { assertNoOwner, cleanup, clearLoginAttempts, countTestUsers, signInUI } from "./admin";
import {
  annotationKinds,
  bumpRev,
  markingOf,
  marksOf,
  penStroke,
  pieceOf,
  pinch,
  removeMarkingExam,
  seedMarkingExam,
  touchDrag,
  type Login,
  type SeededStudent,
} from "./marking";
import { noSidewaysScroll } from "./scripts";

// The marking screen (Phase 3A Task 12) on a computer and on an iPad with Apple Pencil, against the local stack. One
// exam with four verified home scripts; the tests run in order and each takes the next script with Next script:
// the first is marked and submitted, the second is submitted while the marker tries to change it (and Next script on
// the screen then opens the third), the third takes pen and finger and then reports a name, the fourth meets a second
// screen. Every row and file is removed afterwards.

let examId: string;
let marker: Login;
let admin: Login;
let students: SeededStudent[];
let secondUnit: string;

const SURFACE = '[data-testid="page-surface"]';

test.describe.configure({ mode: "serial" });

test.beforeAll(async () => {
  await assertNoOwner();
  ({ examId, marker, admin, students } = await seedMarkingExam({ scripts: 4 }));
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterAll(async () => {
  if (examId) await removeMarkingExam(examId);
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

/** Signs the marker in, presses Next script and waits for the screen; returns the piece's id. */
async function nextScript(page: Page): Promise<string> {
  await signInUI(page, marker.email, marker.password);
  await page.waitForURL((u) => !u.pathname.startsWith("/login"));
  await page.goto("/marking");
  await page.getByRole("button", { name: /^Next script/ }).first().click();
  await page.waitForURL(/\/marking\/[0-9a-f-]{36}$/);
  const unitId = page.url().split("/").pop()!;
  await expect(page.getByTestId("page-surface")).toBeVisible();
  return unitId;
}

const saved = (page: Page) => expect(page.getByTestId("save-status")).toHaveText("Saved");
const SUBMIT_RPC = "**/rest/v1/rpc/marking_submit";

test.describe("on a computer", () => {
  test.use({ viewport: { width: 1440, height: 900 } });

  test("desktop_marks_and_submits", async ({ page }) => {
    const unitId = await nextScript(page);
    const piece = await pieceOf(unitId);
    await expect(page.getByTestId("index-number")).toHaveText(piece.indexNumber);
    await expect(page.getByText("Name hidden", { exact: true })).toBeVisible();
    await expect(page.getByRole("heading", { level: 1 })).toHaveCount(1);
    const html = await page.content();
    for (const s of students) {
      expect(html).not.toContain(s.firstName);
      expect(html).not.toContain(s.lastName);
    }

    // A tick on the page, with the mouse.
    await page.getByRole("button", { name: "Tick", exact: true }).click();
    await page.getByTestId("page-surface").click({ position: { x: 200, y: 160 } });
    await expect.poll(() => annotationKinds(unitId)).toEqual(["tick"]);

    // 3 for question 1 from the keyboard, Enter to the next question, the rest with the buttons.
    await page.keyboard.press("3");
    await expect(page.getByTestId("question-1-mark")).toHaveText("3");
    await page.keyboard.press("Enter");
    await page.getByRole("button", { name: "2 marks", exact: true }).click();
    await page.getByTestId("question-3").click();
    await page.getByRole("button", { name: "4 marks", exact: true }).click();
    await saved(page);
    await expect.poll(() => marksOf(unitId)).toEqual({ "1": 3, "2": 2, "3": 4 });
    await expect(page.getByTestId("running-total")).toHaveText("9 / 15");

    // Everything is still there after a reload.
    await page.reload();
    await expect(page.getByTestId("question-1-mark")).toHaveText("3");
    await expect(page.getByTestId("question-2-mark")).toHaveText("2");
    await expect(page.getByTestId("question-3-mark")).toHaveText("4");
    await page.getByTestId("question-1").click();
    await expect(page.locator('[data-annotation-kind="tick"]')).toHaveCount(1);

    // Submit, then a change asks for a reason and moves the total.
    await page.getByRole("button", { name: "Submit", exact: true }).click();
    await expect(page.getByText("Submitted. You can still change it until marking closes.")).toBeVisible();
    await expect.poll(async () => (await markingOf(unitId))?.status).toBe("submitted");
    await page.getByTestId("question-3").click();
    await page.getByRole("button", { name: "5 marks", exact: true }).click();
    const dialog = page.getByRole("dialog");
    await expect(dialog).toContainText("reason");
    await dialog.getByLabel("Reason").fill("Second look at the method");
    await dialog.getByRole("button", { name: "Save the change" }).click();
    await saved(page);
    await expect(page.getByTestId("running-total")).toHaveText("10 / 15");
    await expect.poll(async () => (await markingOf(unitId))?.total).toBe(10);
    await noSidewaysScroll(page, "the marking screen");
  });

  test("submit_takes_no_input_while_it_runs", async ({ page }) => {
    const unitId = await nextScript(page);
    for (const [label, mark] of [["1", "2 marks"], ["2", "1 mark"], ["3", "3 marks"]]) {
      await page.getByTestId(`question-${label}`).click();
      await page.getByRole("button", { name: mark, exact: true }).click();
    }
    await page.getByRole("button", { name: "Tick", exact: true }).click();
    await saved(page);
    await expect.poll(() => marksOf(unitId)).toEqual({ "1": 2, "2": 1, "3": 3 });

    // marking_submit is held back while the marker tries to change the script.
    let release = () => {};
    const held = new Promise<void>((done) => (release = done));
    await page.route(SUBMIT_RPC, async (route) => {
      if (route.request().method() === "POST") await held;
      await route.continue();
    });
    let saves = 0;
    page.on("request", (r) => {
      if (r.url().includes("/rest/v1/rpc/marking_save")) saves++;
    });
    await page.getByRole("button", { name: "Submit", exact: true }).click();
    await expect(page.getByRole("button", { name: "Submitting…" })).toBeDisabled();
    // Input has stopped: the mark buttons and the tools are disabled, the page takes no tick, a key changes nothing.
    await expect(page.getByRole("button", { name: "5 marks", exact: true })).toBeDisabled();
    await expect(page.getByRole("button", { name: "Tick", exact: true })).toBeDisabled();
    await page.keyboard.press("5");
    await page.getByTestId("page-surface").click({ position: { x: 200, y: 160 } });
    await expect(page.getByTestId("question-3-mark")).toHaveText("3");
    await expect(page.locator('[data-annotation-kind="tick"]')).toHaveCount(0);
    expect(saves).toBe(0);
    release();

    // Submitted, and "Saved" is true: nothing was sent at the old rev and nothing is waiting.
    await expect(page.getByText("Submitted. You can still change it until marking closes.")).toBeVisible();
    await saved(page);
    await page.unroute(SUBMIT_RPC);
    await expect.poll(async () => (await markingOf(unitId))?.status).toBe("submitted");
    expect(saves).toBe(0);
    expect(await marksOf(unitId)).toEqual({ "1": 2, "2": 1, "3": 3 });
    expect(await annotationKinds(unitId)).toEqual([]);

    // Next script on the screen opens the next script.
    await page.getByRole("button", { name: "Next script", exact: true }).click();
    await page.waitForURL((u) => /^\/marking\/[0-9a-f-]{36}$/.test(u.pathname) && !u.pathname.endsWith(unitId));
    // The screen left behind (kept hidden by Next.js) holds no copy of the submitted script: only one page is there.
    await expect(page.getByTestId("page-surface")).toHaveCount(1);
    await expect(page.getByTestId("page-surface")).toBeVisible();
    await expect(page.getByTestId("index-number")).not.toHaveText((await pieceOf(unitId)).indexNumber);
  });
});

test.describe("on an iPad", () => {
  test.use({ viewport: { width: 820, height: 1180 }, hasTouch: true });

  test("ipad_pen_draws_and_finger_scrolls", async ({ page }) => {
    const unitId = await nextScript(page);
    secondUnit = unitId;

    // The pen draws.
    await page.getByRole("button", { name: "Pen", exact: true }).click();
    await penStroke(page, SURFACE, [[0.2, 0.3], [0.25, 0.32], [0.3, 0.35], [0.35, 0.36], [0.4, 0.38]]);
    await expect.poll(() => annotationKinds(unitId)).toEqual(["pen"]);

    // A finger scrolls the page and draws nothing.
    await page.getByRole("button", { name: "Zoom in", exact: true }).click();
    await page.getByRole("button", { name: "Zoom in", exact: true }).click();
    const area = page.getByTestId("page-area");
    const before = await area.evaluate((el) => el.scrollTop);
    await touchDrag(page, SURFACE, [0.5, 0.6], [0.5, 0.2]);
    await expect.poll(() => area.evaluate((el) => el.scrollTop)).toBeGreaterThan(before);

    // Two fingers zoom.
    const zoom = await page.getByTestId("zoom-figure").textContent();
    await pinch(page, SURFACE, 1.6);
    await expect(page.getByTestId("zoom-figure")).not.toHaveText(zoom ?? "");

    // A finger that touches while the pen is down adds nothing, even with Draw with finger on.
    await page.getByRole("button", { name: "Draw with finger" }).click();
    await penStroke(page, SURFACE, [[0.3, 0.3], [0.32, 0.31], [0.34, 0.33], [0.36, 0.34]], { touchDuring: [[0.6, 0.6], [0.65, 0.62], [0.7, 0.64]] });
    await saved(page);
    await expect.poll(() => annotationKinds(unitId)).toEqual(["pen", "pen"]);

    // A stroke the browser breaks off (pointercancel) is kept as far as it went.
    await penStroke(page, SURFACE, [[0.5, 0.5], [0.55, 0.52], [0.6, 0.55], [0.65, 0.56]], { cancel: true });
    await saved(page);
    await expect.poll(() => annotationKinds(unitId)).toEqual(["pen", "pen", "pen"]);

    // The questions drawer takes no shortcut; Escape closes it and focus goes back to the button that opened it.
    const questions = page.getByRole("button", { name: "Questions", exact: true });
    await questions.click();
    const drawer = page.getByRole("dialog", { name: "Questions" });
    await expect(drawer).toBeVisible();
    await page.keyboard.press("3");
    await page.keyboard.press("Escape");
    await expect(drawer).toHaveCount(0);
    await expect(questions).toBeFocused();
    await expect(page.getByTestId("question-1-mark")).toHaveText("–");
    await saved(page);
    await noSidewaysScroll(page, "the marking screen on an iPad");
  });
});

test.describe("on a phone", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("phone_is_told_to_use_a_bigger_screen", async ({ page }) => {
    const signs: string[] = [];
    page.on("request", (r) => {
      if (r.url().includes("/storage/v1/object/sign/")) signs.push(r.url());
    });
    await signInUI(page, marker.email, marker.password);
    await page.waitForURL((u) => !u.pathname.startsWith("/login"));
    await page.goto(`/marking/${secondUnit}`);
    await expect(page.getByText("Marking needs a computer or an iPad.")).toBeVisible();
    await expect(page.getByRole("link", { name: /Marking/ })).toBeVisible();
    await page.waitForLoadState("networkidle");
    expect(signs).toEqual([]);
    // No sideways scroll at the phone's own width (a wider window would open the piece).
    await expect
      .poll(() => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth), { message: "the phone message at 390 px wide" })
      .toBeLessThanOrEqual(0);
  });
});

test.describe("reporting a name", () => {
  test.use({ viewport: { width: 1440, height: 900 } });

  test("name_visible_takes_the_piece_away", async ({ page, browser }) => {
    const unitId = await nextScript(page);
    expect(unitId).toBe(secondUnit);
    const { scriptNumber } = await pieceOf(unitId);
    const nameVisible = page.getByRole("button", { name: "Name visible" });

    // Cancelled, the box gives focus back to the button that opened it.
    await nameVisible.click();
    await page.keyboard.press("Escape");
    await expect(page.getByRole("dialog")).toHaveCount(0);
    await expect(nameVisible).toBeFocused();

    // A mark given just before is saved before the script leaves.
    const order: string[] = [];
    page.on("request", (r) => {
      const m = /\/rest\/v1\/rpc\/(marking_save|marking_name_visible)$/.exec(new URL(r.url()).pathname);
      if (m && r.method() === "POST") order.push(m[1]);
    });
    const saveAnswer = page.waitForResponse((r) => r.url().includes("/rest/v1/rpc/marking_save") && r.request().method() === "POST");
    await page.keyboard.press("2");
    await nameVisible.click();
    const dialog = page.getByRole("dialog");
    await expect(dialog).toContainText("Does this page show the candidate's name? The script will go back to staff and leave your list.");
    await expect(dialog).toContainText("Page 1");
    await expect(dialog.getByRole("textbox")).toHaveCount(0);
    await dialog.getByRole("button", { name: "Name visible" }).click();
    expect((await (await saveAnswer).json()).ok).toBe(true);
    await page.waitForURL(/\/marking$/);
    expect(order).toEqual(["marking_save", "marking_name_visible"]);
    await expect(page.getByRole("region", { name: "Your scripts" })).not.toContainText(scriptNumber);

    const staff = await browser.newPage();
    await signInUI(staff, admin.email, admin.password);
    await staff.waitForURL((u) => !u.pathname.startsWith("/login"));
    await staff.goto(`/admin/scripts/exceptions?exam=${examId}&kind=name_visible`);
    await expect(staff.getByTestId("exception-list")).toContainText("Name visible");
    await expect(staff.getByTestId("exception-found")).toContainText("A marker reported that a name can be seen on this page.");
    await staff.close();
  });

  test("second_screen_is_told_to_reload", async ({ page }) => {
    const unitId = await nextScript(page);
    expect(unitId).not.toBe(secondUnit);
    await page.keyboard.press("1");
    await saved(page);
    await bumpRev(unitId);

    let saves = 0;
    page.on("request", (r) => {
      if (r.url().includes("/rest/v1/rpc/marking_save")) saves++;
    });
    await page.keyboard.press("2");
    await expect(page.getByText("This script was changed on another screen. Reload to carry on.")).toBeVisible();
    const sent = saves;
    expect(sent).toBe(1);
    // Input has stopped: a key press changes nothing and nothing more is sent.
    await page.keyboard.press("4");
    await expect(page.getByTestId("question-1-mark")).toHaveText("2");
    await page.waitForLoadState("networkidle");
    expect(saves).toBe(sent);
  });
});
