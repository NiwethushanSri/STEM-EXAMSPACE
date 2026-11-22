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
// exam with three verified home scripts; the tests run in order and each takes the next script with Next script:
// the first is marked and submitted, the second takes pen and finger and then reports a name, the third meets a
// second screen. Every row and file is removed afterwards.

let examId: string;
let marker: Login;
let admin: Login;
let students: SeededStudent[];
let secondUnit: string;

const SURFACE = '[data-testid="page-surface"]';

test.describe.configure({ mode: "serial" });

test.beforeAll(async () => {
  await assertNoOwner();
  ({ examId, marker, admin, students } = await seedMarkingExam({ scripts: 3 }));
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

test.describe("on a computer", () => {
  test.use({ viewport: { width: 1440, height: 900 } });

  test("desktop_marks_and_submits", async ({ page }) => {
    const unitId = await nextScript(page);
    const piece = await pieceOf(unitId);
    await expect(page.getByTestId("index-number")).toHaveText(piece.indexNumber);
    await expect(page.getByText("Name hidden", { exact: true })).toBeVisible();
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
  });
});

test.describe("reporting a name", () => {
  test.use({ viewport: { width: 1440, height: 900 } });

  test("name_visible_takes_the_piece_away", async ({ page, browser }) => {
    const unitId = await nextScript(page);
    expect(unitId).toBe(secondUnit);
    const { scriptNumber } = await pieceOf(unitId);
    await page.getByRole("button", { name: "Name visible" }).click();
    const dialog = page.getByRole("dialog");
    await expect(dialog).toContainText("Does this page show the candidate's name? The script will go back to staff and leave your list.");
    await expect(dialog).toContainText("Page 1");
    await expect(dialog.getByRole("textbox")).toHaveCount(0);
    await dialog.getByRole("button", { name: "Name visible" }).click();
    await page.waitForURL(/\/marking$/);
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
