import { expect, test, type BrowserContext, type Page } from "@playwright/test";
import { ANON_KEY, SUPABASE_URL, assertNoOwner, cleanup, clearLoginAttempts, countTestUsers, signInUI } from "./admin";
import {
  SUPABASE_BROWSER_SCRIPT,
  annotationKinds,
  bumpRev,
  changePicture,
  holdersOf,
  makeLead,
  markingOf,
  marksOf,
  penStroke,
  pieceOf,
  piecePictures,
  pinch,
  removeMarkingExam,
  seedMarkingExam,
  takeBackPieces,
  touchDrag,
  unitHold,
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
const MY_WORK_RPC = "**/rest/v1/rpc/marking_my_work";

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
    // Question 3 is out of 15: a digit goes to the mark box and replaces the mark there (1, then 4, is 4, not 14).
    await page.getByTestId("question-3").click();
    await page.getByRole("button", { name: "1 mark", exact: true }).click();
    await page.keyboard.press("4");
    await expect(page.getByLabel("Mark (0 to 15)")).toBeFocused();
    await expect(page.getByLabel("Mark (0 to 15)")).toHaveValue("4");
    await page.keyboard.press("Enter");
    await expect(page.getByTestId("question-3-mark")).toHaveText("4");
    await saved(page);
    await expect.poll(() => marksOf(unitId)).toEqual({ "1": 3, "2": 2, "3": 4 });
    await expect(page.getByTestId("running-total")).toHaveText("9 / 24");

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
    await expect(page.getByTestId("running-total")).toHaveText("10 / 24");
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

    // Next script on the screen recovers from a failure: a plain message, and it can be pressed again.
    const next = page.getByRole("button", { name: "Next script", exact: true });
    await page.route(MY_WORK_RPC, (route) => (route.request().method() === "POST" ? route.abort() : route.continue()));
    await next.click();
    await expect(page.getByText("Could not find a script. Check your connection and try again.")).toBeVisible();
    await expect(next).toBeEnabled();
    await page.unroute(MY_WORK_RPC);

    // Then it opens the next script.
    await next.click();
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

    // Open, then the window made 1200 px or wider: the drawer closes, and the shortcuts work again.
    await questions.click();
    await expect(drawer).toBeVisible();
    await page.setViewportSize({ width: 1280, height: 1180 });
    await expect(drawer).toHaveCount(0);
    const zoomed = await page.getByTestId("zoom-figure").textContent();
    await page.keyboard.press("[");
    await expect(page.getByTestId("zoom-figure")).not.toHaveText(zoomed ?? "");
    await noSidewaysScroll(page, "the marking screen on an iPad");
  });
});

test.describe("on a phone", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("phone_is_told_to_use_a_bigger_screen", async ({ page }) => {
    const signs: string[] = [];
    page.on("request", (r) => {
      if (r.url().includes("/storage/v1/object/sign/") || r.url().includes("/functions/v1/marking-pictures")) signs.push(r.url());
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

    // A mark given just before leaving through the Marking link is saved first.
    await page.keyboard.press("1");
    await page.getByRole("link", { name: "Back to Marking" }).click();
    await page.waitForURL(/\/marking$/);
    await expect.poll(() => marksOf(unitId)).toEqual({ "1": 1 });

    // Back to the script: the screen Next.js kept is opened afresh, with what was saved.
    await page.goBack();
    await page.waitForURL(/\/marking\/[0-9a-f-]{36}$/);
    await expect(page.getByTestId("page-surface")).toHaveCount(1);
    await expect(page.getByTestId("question-1-mark")).toHaveText("1");
    await saved(page);
    await page.getByTestId("question-1").click();
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

// Two real sessions (final review I3), on an exam of their own with one script and two approved markers: both markers
// press Next script at the same moment; the marker who got the piece then has it open on two screens; and a page taken
// back while it is only being read leaves the screen within a minute (M1). Each session is its own browser context.
test.describe("two sessions", () => {
  test.use({ viewport: { width: 1440, height: 900 } });

  let raceExam: string;
  let raceAdmin: Login;
  let racers: Login[];
  let raceStudents: SeededStudent[];
  let winner: Login;
  let raceUnit: string;
  const contexts: BrowserContext[] = [];

  test.beforeAll(async () => {
    const seed = await seedMarkingExam({ scripts: 1, markers: 2 });
    raceExam = seed.examId;
    raceAdmin = seed.admin;
    racers = seed.markers;
    raceStudents = seed.students;
  });
  test.afterEach(async () => {
    for (const c of contexts.splice(0)) await c.close();
  });
  test.afterAll(async () => {
    if (raceExam) await removeMarkingExam(raceExam);
  });

  /** A signed-in session of its own (a new browser context) for a marker. */
  async function session(browser: import("@playwright/test").Browser, who: Login, opts: { clock?: boolean } = {}): Promise<Page> {
    const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, baseURL: test.info().project.use.baseURL });
    contexts.push(context);
    const p = await context.newPage();
    if (opts.clock) await p.clock.install();
    await signInUI(p, who.email, who.password);
    await p.waitForURL((u) => !u.pathname.startsWith("/login"));
    return p;
  }
  const HOLD_ENDED = "Your hold on this script has ended. Press Next script to carry on.";
  const onPiece = (p: Page) => /^\/marking\/[0-9a-f-]{36}$/.test(new URL(p.url()).pathname);

  test("two_markers_one_piece_left", async ({ browser }) => {
    const pages = [await session(browser, racers[0]), await session(browser, racers[1])];
    const buttons = [];
    for (const p of pages) {
      await p.goto("/marking");
      const next = p.getByRole("button", { name: /^Next script/ }).first();
      await expect(next).toBeEnabled();
      buttons.push(next);
    }
    // Both press at the same moment, with one piece left.
    await Promise.all(buttons.map((b) => b.click()));
    await expect
      .poll(async () => {
        const nothing = await Promise.all(pages.map((p) => p.getByText("Nothing left to mark for now.").isVisible()));
        return pages.map((p, i) => (onPiece(p) ? "piece" : nothing[i] ? "nothing" : "waiting")).sort().join(" ");
      })
      .toBe("nothing piece");
    const got = onPiece(pages[0]) ? 0 : 1;
    winner = racers[got];
    raceUnit = new URL(pages[got].url()).pathname.split("/").pop()!;
    await expect(pages[got].getByTestId("page-surface")).toBeVisible();
    // The other marker stays on the marking home with the plain words and no piece.
    await expect(pages[1 - got].getByText("Nothing left to mark for now.")).toBeVisible();
    expect(new URL(pages[1 - got].url()).pathname).toBe("/marking");
    // Exactly one holder, and one marking at most: nobody marks the script twice.
    expect(await holdersOf(raceExam)).toEqual([{ unitId: raceUnit, holder: winner.id }]);
    for (const p of pages) {
      const html = await p.content();
      for (const s of raceStudents) {
        expect(html).not.toContain(s.firstName);
        expect(html).not.toContain(s.lastName);
      }
    }
  });

  test("one_marker_two_screens_second_save_is_refused", async ({ browser }) => {
    const first = await session(browser, winner);
    const second = await session(browser, winner);
    for (const p of [first, second]) {
      await p.goto(`/marking/${raceUnit}`);
      await expect(p.getByTestId("page-surface")).toBeVisible();
      await saved(p);
    }
    let secondSaves = 0;
    second.on("request", (r) => {
      if (r.url().includes("/rest/v1/rpc/marking_save")) secondSaves++;
    });

    // The first screen saves 3 for question 1 and a tick.
    await first.keyboard.press("3");
    await first.getByRole("button", { name: "Tick", exact: true }).click();
    await first.getByTestId("page-surface").click({ position: { x: 200, y: 160 } });
    await saved(first);
    await expect.poll(() => marksOf(raceUnit)).toEqual({ "1": 3 });
    await expect.poll(() => annotationKinds(raceUnit)).toEqual(["tick"]);
    const rev = (await markingOf(raceUnit))!.rev;

    // The second screen, opened before that save, then saves: it is told to reload and nothing it holds is written.
    await second.keyboard.press("1");
    await expect(second.getByText("This script was changed on another screen. Reload to carry on.")).toBeVisible();
    expect(secondSaves).toBe(1);
    await second.keyboard.press("4");
    await second.waitForLoadState("networkidle");
    expect(secondSaves).toBe(1);
    expect(await marksOf(raceUnit)).toEqual({ "1": 3 });
    expect(await annotationKinds(raceUnit)).toEqual(["tick"]);
    expect((await markingOf(raceUnit))!.rev).toBe(rev);
    // The first screen carries on.
    await first.keyboard.press("Enter");
    await first.getByRole("button", { name: "2 marks", exact: true }).click();
    await saved(first);
    await expect.poll(() => marksOf(raceUnit)).toEqual({ "1": 3, "2": 2 });

    // Reloaded, the second screen shows what the first saved.
    await second.reload();
    await expect(second.getByTestId("question-1-mark")).toHaveText("3");
    await expect(second.getByTestId("question-2-mark")).toHaveText("2");
  });

  test("a_page_taken_back_leaves_the_screen_within_a_minute", async ({ browser }) => {
    // The page's own clock is in the test's hands, so the minute does not have to be waited for.
    const p = await session(browser, winner, { clock: true });
    await p.goto(`/marking/${raceUnit}`);
    const picture = p.getByTestId("page-surface").locator("img");
    await expect(picture).toBeVisible();
    let saves = 0;
    p.on("request", (r) => {
      if (r.url().includes("/rest/v1/rpc/marking_save")) saves++;
    });

    // Still the marker's: a minute passes and the page stays.
    await p.clock.fastForward(61_000);
    await p.waitForLoadState("networkidle");
    await expect(picture).toBeVisible();
    await expect(p.getByText(HOLD_ENDED)).toHaveCount(0);

    // The admin takes the piece back while the marker only reads: nothing is saved, so no save can tell the screen.
    await takeBackPieces(raceAdmin, [raceUnit], "Another marker will take it");
    expect(await holdersOf(raceExam)).toEqual([]);
    await p.clock.fastForward(61_000);
    await expect(p.getByText(HOLD_ENDED)).toBeVisible();
    await expect(p.getByTestId("page-surface").locator("img")).toHaveCount(0);
    await expect(p.locator('img[src*="/storage/v1/object/sign/"]')).toHaveCount(0);
    expect(saves).toBe(0);
  });
});

// Picture links signed on the server (Phase 3B Task 1, Ruling R12), on an exam of its own with one script, its marker
// and a lead marker: the marker's screen is given no picture's path and shows its pages through links the
// marking-pictures function signed, and the marker cannot make a link themselves; then a page's picture changes and the
// lead looks at the changed page before releasing the script.
test.describe("picture links", () => {
  test.use({ viewport: { width: 1440, height: 900 } });

  let linkExam: string;
  let linkMarker: Login;
  let linkStudents: SeededStudent[];
  let linkUnit: string;

  test.beforeAll(async () => {
    const seed = await seedMarkingExam({ scripts: 1 });
    linkExam = seed.examId;
    linkMarker = seed.marker;
    linkStudents = seed.students;
  });
  test.afterAll(async () => {
    if (linkExam) await removeMarkingExam(linkExam);
  });

  /** The picture has loaded (its width is known). */
  const loaded = (img: import("@playwright/test").Locator) => img.evaluate((i: HTMLImageElement) => (i.complete ? i.naturalWidth : 0));

  test("marker_cannot_make_a_picture_link_themselves", async ({ page }) => {
    const answers: string[] = [];
    page.on("response", async (r) => {
      if (r.url().includes("/rest/v1/rpc/marking_unit_open") && r.request().method() === "POST") answers.push(await r.text());
    });
    await signInUI(page, linkMarker.email, linkMarker.password);
    await page.waitForURL((u) => !u.pathname.startsWith("/login"));
    await page.goto("/marking");
    await page.getByRole("button", { name: /^Next script/ }).first().click();
    await page.waitForURL(/\/marking\/[0-9a-f-]{36}$/);
    linkUnit = page.url().split("/").pop()!;

    // The page shows through a link the function signed; the piece's answer holds no picture's path.
    const picture = page.getByTestId("page-surface").locator("img");
    await expect.poll(() => loaded(picture)).toBeGreaterThan(0);
    expect(await picture.getAttribute("src")).toContain("/storage/v1/object/sign/script-pages/");
    expect(answers.length).toBeGreaterThan(0);
    for (const a of answers) expect(a).not.toContain("-marking.jpg");

    // With the paths read here (the service key), the marker's own session in the page can neither sign nor read them.
    const [first] = await piecePictures(linkUnit);
    await page.addScriptTag({ path: SUPABASE_BROWSER_SCRIPT });
    const tried = await page.evaluate(
      async ({ url, key, email, password, paths }) => {
        type Sb = typeof import("@supabase/supabase-js");
        const sb = (window as unknown as { supabase: Sb }).supabase.createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
        const signIn = await sb.auth.signInWithPassword({ email, password });
        if (signIn.error) return [`sign-in failed: ${signIn.error.message}`];
        const out: string[] = [];
        for (const p of paths) {
          const link = await sb.storage.from("script-pages").createSignedUrl(p, 3600);
          const read = await sb.storage.from("script-pages").download(p);
          out.push(`${link.error ? "no link" : "link"} ${read.error ? "no read" : "read"}`);
        }
        await sb.auth.signOut({ scope: "local" });
        return out;
      },
      { url: SUPABASE_URL, key: ANON_KEY, email: linkMarker.email, password: linkMarker.password, paths: [first.markingPath, first.fullPath] },
    );
    expect(tried).toEqual(["no link no read", "no link no read"]);
  });

  test("lead_views_the_changed_page_before_release", async ({ page }) => {
    const lead = await makeLead(linkExam);
    const { scriptNumber } = await pieceOf(linkUnit);
    const changed = (await piecePictures(linkUnit))[1];
    const newPath = await changePicture(changed.pageId);
    await expect.poll(() => unitHold(linkUnit)).toBe("true picture_changed");

    let links = 0;
    page.on("request", (r) => {
      if (r.url().includes("/functions/v1/marking-pictures") && r.method() === "POST") links++;
    });
    await signInUI(page, lead.email, lead.password);
    await page.waitForURL((u) => !u.pathname.startsWith("/login"));
    await page.goto("/marking");
    const attention = page.getByRole("region", { name: "Needs your attention", exact: true });
    await attention.getByRole("button", { name: `View pages of script ${scriptNumber}` }).click();

    // The viewer opens on the changed page, marked, with its new picture.
    const viewer = page.getByRole("dialog", { name: `Pages of script ${scriptNumber}` });
    await expect(viewer).toContainText("Page 2 of 3");
    await expect(viewer.getByText("Changed", { exact: true })).toBeVisible();
    const two = viewer.getByRole("img", { name: "Page 2" });
    await expect.poll(() => loaded(two)).toBeGreaterThan(0);
    expect(await two.getAttribute("src")).toContain(newPath);
    // The other pages are there too.
    await viewer.getByRole("button", { name: "Previous page" }).click();
    await expect(viewer).toContainText("Page 1 of 3");
    await expect.poll(() => loaded(viewer.getByRole("img", { name: "Page 1" }))).toBeGreaterThan(0);
    expect(links).toBeGreaterThanOrEqual(2);
    const html = await page.content();
    for (const s of linkStudents) {
      expect(html).not.toContain(s.firstName);
      expect(html).not.toContain(s.lastName);
    }
    await viewer.getByRole("button", { name: "Close" }).click();
    await expect(viewer).toHaveCount(0);

    // Then the lead releases it, and the marker's piece is no longer on hold.
    await attention.getByRole("button", { name: `Release script ${scriptNumber}` }).click();
    const dialog = page.getByRole("dialog", { name: `Release script ${scriptNumber}` });
    await dialog.getByLabel("Reason").fill("The new picture is fine");
    await dialog.getByRole("button", { name: "Release", exact: true }).click();
    await expect(dialog).toBeHidden();
    await expect.poll(() => unitHold(linkUnit)).toBe("false null");
  });
});
