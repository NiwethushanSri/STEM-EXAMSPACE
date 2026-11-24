import { expect, test, type Page, type Request, type Response } from "@playwright/test";
import { SUPABASE_URL, assertNoOwner, cleanup, clearLoginAttempts, countTestUsers, signInUI } from "./admin";
import {
  LEAD_MARKS,
  QUESTIONS,
  STANDARD_NOTE,
  annotationKinds,
  checkStateOf,
  clearMarker,
  holdsOn,
  markAs,
  nextAs,
  pauseMarker,
  pieceOf,
  removeMarkingExam,
  seedCheckedExam,
  setUntilSeed,
  standardsOf,
  type Login,
  type SeededStudent,
} from "./marking";

// What the marker sees of the checks on the marking (Phase 3B Task 6), against the local stack, on a computer (1440 x
// 900) and an iPad (820 x 1180): practice scripts and what they are told after each, a seeded script that looks like
// any other until it is marked outside tolerance (Review Focus 1) and is then locked, a second marker who sees nothing
// of the first marking, and a paused marker. Each test has an exam of its own (seedCheckedExam: the lead marker's own
// marking makes the practice and seeded scripts), except that the locked seed is the one the test before missed; every
// row and file is removed afterwards.
// Needs the Edge Functions served locally (supabase functions serve --env-file supabase/functions/.env.test.local): the
// screen's picture links come from marking-pictures. npm run e2e:local starts them when they are not served already.

test.describe.configure({ mode: "serial" });

const made: string[] = [];
/** The seeded script seed_looks_like_any_script_until_a_miss marked outside the tolerance, and its marker. */
let missed: { unitId: string; marker: Login } | null = null;

test.beforeAll(async () => {
  await assertNoOwner();
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterAll(async () => {
  for (const id of made.splice(0)) await removeMarkingExam(id);
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

async function checkedExam(opts: Parameters<typeof seedCheckedExam>[0]): ReturnType<typeof seedCheckedExam> {
  const s = await seedCheckedExam(opts);
  made.push(s.examId);
  return s;
}

const SUBMITTED = "Submitted. You can still change it until marking closes.";
const PRACTICE_HEADING = "Practice script. Compare your marks with the lead marker's.";
const SEED_HEADING = "This was a check script. Your marks were outside the tolerance. These are the lead marker's marks.";
const PRACTICE_WAIT = "Your practice scripts are with the lead marker.";
const PAUSED = "Your marking on this exam is paused. The lead marker will be in touch.";
const LOCKED = "This script can no longer be changed.";
const PIECE = /^\/marking\/[0-9a-f-]{36}$/;
const COMPUTER = { width: 1440, height: 900 };
const IPAD = { width: 820, height: 1180 };

async function signIn(page: Page, who: Login): Promise<void> {
  await signInUI(page, who.email, who.password);
  await page.waitForURL((u) => !u.pathname.startsWith("/login"));
}

const unitOf = (page: Page) => new URL(page.url()).pathname.split("/").pop()!;
/** The header of the marking screen on view (Next.js keeps pages it left in the page, hidden). */
const screenHeader = (page: Page) => page.locator("header").filter({ has: page.getByTestId("index-number") });
const saved = (page: Page) => expect(page.getByTestId("save-status")).toHaveText("Saved");
const submit = (page: Page) => page.getByRole("button", { name: "Submit", exact: true }).click();

/** Next script on the marker home (the first exam's card); waits for the screen and returns the piece's id. */
async function nextFromHome(page: Page): Promise<string> {
  await page.goto("/marking");
  await page.getByRole("button", { name: /^Next script/ }).first().click();
  await page.waitForURL((u) => PIECE.test(u.pathname));
  await expect(page.getByTestId("page-surface")).toBeVisible();
  return unitOf(page);
}

/** Next script on the marking screen (after a submit); waits for the next piece and returns its id. */
async function nextOnScreen(page: Page): Promise<string> {
  const before = unitOf(page);
  await page.getByRole("button", { name: "Next script", exact: true }).click();
  await page.waitForURL((u) => PIECE.test(u.pathname) && !u.pathname.endsWith(before));
  await expect(page.getByTestId("page-surface")).toBeVisible();
  return unitOf(page);
}

/** Gives each question its mark with the mark buttons, in paper order, and waits for the save. */
async function giveMarks(page: Page, marks: readonly number[]): Promise<void> {
  for (const [i, m] of marks.entries()) {
    await page.getByTestId(`question-${QUESTIONS[i].label}`).click();
    await page.getByRole("button", { name: `${m} ${m === 1 ? "mark" : "marks"}`, exact: true }).click();
  }
  await saved(page);
}

/** No sideways scroll on a computer and on an iPad; ends at `back`. */
async function noSidewaysScroll(page: Page, what: string, back: { width: number; height: number }): Promise<void> {
  for (const size of [COMPUTER, IPAD]) {
    await page.setViewportSize(size);
    await expect
      .poll(() => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth), { message: `${what} at ${size.width} px wide` })
      .toBeLessThanOrEqual(0);
  }
  await page.setViewportSize(back);
}

/** The page holds none of the candidates' names. */
async function noNames(page: Page, students: SeededStudent[]): Promise<void> {
  const html = await page.content();
  for (const s of students) {
    expect(html).not.toContain(s.firstName);
    expect(html).not.toContain(s.lastName);
  }
}

/** The feedback table's rows: question, your mark, the lead marker's mark, and "Different" or nothing. */
async function feedbackTable(page: Page): Promise<string[][]> {
  const rows = page.getByTestId("feedback-row");
  const out: string[][] = [];
  for (let i = 0; i < (await rows.count()); i++) out.push((await rows.nth(i).locator("th, td").allTextContents()).map((t) => t.trim()));
  return out;
}

test.describe("on a computer", () => {
  test.use({ viewport: COMPUTER });

  test("practice_then_cleared_then_live", async ({ page }) => {
    test.setTimeout(180_000);
    const { examId, lead, markers, students } = await checkedExam({ scripts: 3, checks: { practice: true } });
    const marker = markers[0];
    const practice = (await standardsOf(examId)).map((s) => s.unitId);
    expect(practice).toHaveLength(2);
    await signIn(page, marker);
    await page.goto("/marking");
    const card = page.getByTestId("marking-exam");
    await expect(card.getByTestId("practice-line")).toHaveText("Practice first: 0 of 2 done");

    // The first practice script says so, beside "Name hidden".
    const first = await nextFromHome(page);
    expect(practice).toContain(first);
    await expect(screenHeader(page).getByText("Practice", { exact: true })).toBeVisible();
    await expect(screenHeader(page).getByText("Name hidden", { exact: true })).toBeVisible();

    // Question 3 given 6 against the lead's 10 (more than its tolerance of 1.5): after Submit the page gives way to
    // the marks beside the lead marker's, that question marked Different, both totals and the lead's note.
    await giveMarks(page, [3, 2, 6]);
    await submit(page);
    const panel = page.getByTestId("feedback-panel");
    await expect(panel.getByRole("heading", { name: PRACTICE_HEADING })).toBeVisible();
    expect(await feedbackTable(page)).toEqual([
      ["1", "3", "3", ""],
      ["2", "2", "2", ""],
      ["3", "6", "10", "Different"],
    ]);
    await expect(panel.getByTestId("feedback-total")).toHaveText("11 / 24");
    await expect(panel.getByTestId("feedback-lead-total")).toHaveText("15 / 24");
    await expect(panel).toContainText(STANDARD_NOTE);
    // Nothing can be changed: the page, the marks and Submit are gone, and Next script is on the panel.
    await expect(page.getByTestId("page-surface")).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Submit", exact: true })).toHaveCount(0);
    await expect(page.getByText(SUBMITTED)).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Next script", exact: true })).toHaveCount(1);
    await noSidewaysScroll(page, "the practice feedback", COMPUTER);
    await noNames(page, students);

    // The second, marked as the lead marked it: its feedback marks no question.
    const second = await nextOnScreen(page);
    expect(practice).toContain(second);
    expect(second).not.toBe(first);
    await expect(screenHeader(page).getByText("Practice", { exact: true })).toBeVisible();
    await giveMarks(page, LEAD_MARKS);
    await submit(page);
    await expect(panel.getByRole("heading", { name: PRACTICE_HEADING })).toBeVisible();
    expect((await feedbackTable(page)).map((r) => r[3])).toEqual(["", "", ""]);
    await expect(panel.getByTestId("feedback-total")).toHaveText("15 / 24");

    // No practice script is left: they wait for the lead marker.
    await page.getByRole("button", { name: "Next script", exact: true }).click();
    await expect(page.getByText(PRACTICE_WAIT)).toBeVisible();
    expect(unitOf(page)).toBe(second);
    await page.goto("/marking");
    await expect(card.getByTestId("practice-line")).toHaveText(PRACTICE_WAIT);
    const pieces = page.getByTestId("marking-piece");
    await expect(pieces.filter({ hasText: "Practice" })).toHaveCount(2);
    await noSidewaysScroll(page, "the marker home waiting for the lead marker", COMPUTER);

    // A practice script opened again shows its feedback again.
    const { scriptNumber } = await pieceOf(first);
    await page.getByRole("link", { name: `Open script ${scriptNumber}` }).click();
    await page.waitForURL((u) => u.pathname.endsWith(first));
    await expect(panel.getByRole("heading", { name: PRACTICE_HEADING })).toBeVisible();
    expect((await feedbackTable(page))[2]).toEqual(["3", "6", "10", "Different"]);

    // The lead marker clears them: Next script gives a live script, which says nothing of practice.
    await clearMarker(lead, examId, marker.id);
    await page.goto("/marking");
    await expect(card.getByTestId("practice-line")).toHaveCount(0);
    const live = await nextFromHome(page);
    expect(practice).not.toContain(live);
    await expect(screenHeader(page).getByText("Name hidden", { exact: true })).toBeVisible();
    await expect(screenHeader(page).getByText("Practice", { exact: true })).toHaveCount(0);
    await giveMarks(page, LEAD_MARKS);
    await submit(page);
    await expect(page.getByText(SUBMITTED)).toBeVisible();
    await expect(page.getByTestId("feedback-panel")).toHaveCount(0);
    await noNames(page, students);
  });

  test("seed_looks_like_any_script_until_a_miss", async ({ page }) => {
    test.setTimeout(240_000);
    const { examId, markers, students } = await checkedExam({ scripts: 5, checks: { seeds: true, seed_every: 3 } });
    const marker = markers[0];
    const seeds = (await standardsOf(examId)).map((s) => s.unitId);
    expect(seeds).toHaveLength(2);
    await signIn(page, marker);

    // Their first Next script draws the count to their first seed (at least 1), so it gives a live script. The count
    // is then set high, so no seed comes by chance before the test asks for one.
    const first = await nextFromHome(page);
    expect(seeds).not.toContain(first);
    await setUntilSeed(examId, marker.id, 50);
    await giveMarks(page, LEAD_MARKS);
    await submit(page);
    await expect(page.getByText(SUBMITTED)).toBeVisible();

    // The piece before: a live script opened with Next script on the screen, watched.
    const live = await openWatched(page);
    expect(seeds).not.toContain(live.unitId);
    const liveSubmit = await submitWatched(page);

    // Then the seed, opened the same way once the count has run out (set to 0 here).
    await setUntilSeed(examId, marker.id, 0);
    const seed = await openWatched(page);
    expect(seeds).toContain(seed.unitId);

    // Review Focus 1: nothing on the screen, in the page, in what it asked for or in what it was answered tells them.
    // (The page's data names a practice field, false for every piece but a practice one: the word is "Practice".)
    const html = await page.content();
    for (const word of [/seed/i, /check script/i, /Practice/]) expect(html).not.toMatch(word);
    expect(seed.shape.header).toBe(live.shape.header);
    expect(seed.shape.hold).toBe(live.shape.hold);
    expect(seed.shape.hold).toMatch(/^Held for you until <time>$/);
    expect(seed.shape.tools).toBe(live.shape.tools);
    expect(seed.shape.skeleton).toBe(live.shape.skeleton);
    expect(seed.shape.text).toBe(live.shape.text);
    expect(seed.requests).toEqual(live.requests);
    expect(seed.openKeys).toEqual(live.openKeys);
    // The same hold: theirs alone, by Next script, for two hours from when it was opened.
    for (const w of [live, seed]) {
      expect(w.holds).toHaveLength(1);
      expect(w.holds[0]).toMatchObject({ marker: marker.id, how: "next" });
      expect(w.holds[0].ms).toBeGreaterThanOrEqual(2 * 3600_000);
      expect(w.holds[0].ms).toBeLessThan(2 * 3600_000 + 10 * 60_000);
    }
    await noNames(page, students);

    // Marked inside the tolerance: the normal Submitted state, and the same answer as the live script's.
    const seedSubmit = await submitWatched(page);
    expect(seedSubmit).toEqual(liveSubmit);
    await expect(page.getByTestId("feedback-panel")).toHaveCount(0);

    // The marker's list shows it as any other script.
    await page.goto("/marking");
    const rowOf = async (unitId: string) => {
      const { scriptNumber, indexNumber } = await pieceOf(unitId);
      const text = await page.getByTestId("marking-piece").filter({ hasText: `Script ${scriptNumber}` }).innerText();
      return text.replace(scriptNumber, "<script>").replace(indexNumber, "<index>");
    };
    expect(await rowOf(seed.unitId)).toBe(await rowOf(live.unitId));

    // A second seed, marked outside the tolerance: now they are told, and shown the lead marker's marks.
    await page.goBack();
    await page.waitForURL((u) => u.pathname.endsWith(seed.unitId));
    await expect(page.getByText(SUBMITTED)).toBeVisible();
    await setUntilSeed(examId, marker.id, 0);
    const second = await nextOnScreen(page);
    expect(seeds).toContain(second);
    expect(second).not.toBe(seed.unitId);
    await giveMarks(page, [0, 0, 1]);
    await submit(page);
    const panel = page.getByTestId("feedback-panel");
    await expect(panel.getByRole("heading", { name: SEED_HEADING })).toBeVisible();
    expect(await feedbackTable(page)).toEqual([
      ["1", "0", "3", "Different"],
      ["2", "0", "2", "Different"],
      ["3", "1", "10", "Different"],
    ]);
    await expect(panel.getByTestId("feedback-total")).toHaveText("1 / 24");
    await expect(panel.getByTestId("feedback-lead-total")).toHaveText("15 / 24");
    await expect(panel).toContainText(STANDARD_NOTE);
    await expect(page.getByTestId("page-surface")).toHaveCount(0);
    await noSidewaysScroll(page, "the feedback on a seeded script", COMPUTER);
    await noNames(page, students);
    missed = { unitId: second, marker };
  });

  test("missed_seed_opened_again_refuses_a_change", async ({ page }) => {
    // The seed the test before marked outside the tolerance: its attempt is locked.
    expect(missed).not.toBeNull();
    const { unitId, marker } = missed!;
    await signIn(page, marker);
    await page.goto(`/marking/${unitId}`);
    await expect(page.getByTestId("page-surface")).toBeVisible();
    await expect(page.getByText(SUBMITTED)).toBeVisible();
    await expect(page.getByTestId("question-3-mark")).toHaveText("1");

    // A change is refused (Ruling R12): the screen says why, never "Saved"; the Submitted banner goes; input stops; and
    // the mark on screen is back to its saved value.
    await page.getByTestId("question-3").click();
    await page.getByRole("button", { name: "2 marks", exact: true }).click();
    await expect(page.getByRole("alert").filter({ hasText: LOCKED })).toBeVisible();
    await expect(page.getByTestId("save-status")).toHaveText(LOCKED);
    await expect(page.getByText(SUBMITTED)).toHaveCount(0);
    await expect(page.getByTestId("question-3-mark")).toHaveText("1");
    await expect(page.getByTestId("running-total")).toHaveText("1 / 24");
    await expect(page.getByTestId("page-surface")).toHaveCount(0);
    await expect(page.getByRole("button", { name: "3 marks", exact: true })).toBeDisabled();

    // Opened again, it shows the saved marks only: the refused change was not kept to be sent again.
    await page.reload();
    await expect(page.getByTestId("page-surface")).toBeVisible();
    await expect(page.getByText(SUBMITTED)).toBeVisible();
    await expect(page.getByTestId("question-3-mark")).toHaveText("1");
    await saved(page);
  });

  test("paused_marker_is_told_and_stopped", async ({ page }) => {
    test.setTimeout(180_000);
    const { examId, lead, markers, students } = await checkedExam({ scripts: 2, checks: {} });
    const marker = markers[0];
    await signIn(page, marker);

    // One script submitted, and the next one opened (in progress) before the pause.
    const done = await nextFromHome(page);
    await giveMarks(page, LEAD_MARKS);
    await submit(page);
    await expect(page.getByText(SUBMITTED)).toBeVisible();
    const held = await nextOnScreen(page);
    await saved(page);
    await page.goto(`/marking/${done}`);
    await expect(page.getByText(SUBMITTED)).toBeVisible();
    await expect(page.getByTestId("page-surface").locator("img")).toBeVisible();

    // The lead marker pauses them. A change to the submitted script is refused: the page gives way to the sentence,
    // and input stops.
    await pauseMarker(lead, examId, marker.id);
    await page.getByTestId("question-3").click();
    await page.getByRole("button", { name: "9 marks", exact: true }).click();
    await expect(page.getByRole("alert").filter({ hasText: PAUSED })).toBeVisible();
    await expect(page.getByTestId("page-surface")).toHaveCount(0);
    await expect(page.getByRole("button", { name: "8 marks", exact: true })).toBeDisabled();
    await expect(page.locator('img[src*="/storage/v1/object/sign/"]')).toHaveCount(0);
    await noSidewaysScroll(page, "the screen of a paused marker", COMPUTER);

    // The marker home says so, with no Next script for the exam.
    await page.goto("/marking");
    const card = page.getByTestId("marking-exam");
    await expect(card.getByText(PAUSED)).toBeVisible();
    await expect(card.getByRole("button", { name: /^Next script/ })).toHaveCount(0);
    await noSidewaysScroll(page, "the marker home of a paused marker", COMPUTER);

    // The script they had in progress does not open.
    await page.goto(`/marking/${held}`);
    await expect(page.getByText(PAUSED)).toBeVisible();
    await expect(page.getByTestId("page-surface")).toHaveCount(0);
    await noNames(page, students);
  });
});

test.describe("on an iPad", () => {
  test.use({ viewport: IPAD, hasTouch: true });

  test("second_marker_sees_a_clean_script", async ({ page }) => {
    test.setTimeout(180_000);
    const { examId, markers, students } = await checkedExam({ scripts: 1, checks: { double_marking: true, sample_percent: 100 }, markers: 2 });
    const [first, second] = markers;

    // The first marker marks the script with a tick, marks and a note; it waits for a second marker (100% sample).
    const unitId = await nextAs(first, examId);
    await markAs(first, unitId, [...LEAD_MARKS], { tick: true, note: "Question 3: units missing." });
    expect(await annotationKinds(unitId)).toEqual(["tick"]);
    expect(await checkStateOf(unitId)).toBe("waiting_second");

    // The second marker's Next script gives them that script's second pass, with nothing of the first marking.
    await signIn(page, second);
    expect(await nextFromHome(page)).toBe(unitId);
    expect(await holdsOn(unitId)).toEqual([expect.objectContaining({ marker: second.id, kind: "second", how: "next" })]);
    await expect(page.getByTestId("page-surface").locator("img")).toBeVisible();
    await expect(page.locator("[data-annotation-kind]")).toHaveCount(0);
    for (const q of QUESTIONS) await expect(page.getByTestId(`question-${q.label}-mark`)).toHaveText("–");
    await expect(page.getByTestId("running-total")).toHaveText("0 / 24");
    await expect(page.getByLabel("Private note to the lead marker")).toHaveValue("");
    await expect(screenHeader(page).getByText("Practice", { exact: true })).toHaveCount(0);
    for (const n of [2, 3]) {
      await page.getByRole("button", { name: "Next page", exact: true }).click();
      await expect(page.getByTestId("page-surface")).toHaveAccessibleName(new RegExp(`^Page ${n} of 3`));
      await expect(page.locator("[data-annotation-kind]")).toHaveCount(0);
    }
    expect(await page.content()).not.toContain("Question 3: units missing.");
    await noNames(page, students);
    await noSidewaysScroll(page, "the second marker's screen", IPAD);
  });
});

/** What a piece's screen shows and asked for, read once it has settled (picture shown, everything saved). */
type Watched = {
  unitId: string;
  shape: { header: string; hold: string; tools: string; skeleton: string; text: string };
  /** Every request to the database, the functions and the storage, and every server action, from the press of Next
   * script until the screen settled: method, path and body with ids and times taken out, sorted. */
  requests: string[];
  /** The key paths of marking_unit_open's answer. */
  openKeys: string[];
  /** The open holds on the piece once it opened: who, how and for how long. */
  holds: { marker: string; how: string; ms: number | null }[];
};

const ID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g;

/** A request without what differs from piece to piece by nature: ids, and query values (signed links, router keys). */
function requestLine(r: Request, appOrigin: string): string | null {
  const url = new URL(r.url());
  const db = url.origin === new URL(SUPABASE_URL).origin && !url.pathname.startsWith("/auth/");
  const action = url.origin === appOrigin && r.method() === "POST";
  if (!db && !action) return null;
  const query = [...url.searchParams.keys()].sort().join("&");
  const body = (r.postData() ?? "").replace(ID, "<id>");
  return `${r.method()} ${url.pathname.replace(ID, "<id>")}${query ? `?${query}` : ""} ${body}`;
}

/** Every key path of a JSON value ("marking.practice", "pages[].has_picture"), sorted. */
function keyPaths(v: unknown, at = ""): string[] {
  if (Array.isArray(v)) return [...new Set(v.flatMap((x) => keyPaths(x, `${at}[]`)))].sort();
  if (v && typeof v === "object") return Object.entries(v).flatMap(([k, x]) => [`${at}${at ? "." : ""}${k}`, ...keyPaths(x, `${at}${at ? "." : ""}${k}`)]).sort();
  return [];
}

/** Presses Next script on the screen and watches the next piece open until it has settled. */
async function openWatched(page: Page): Promise<Watched> {
  const appOrigin = new URL(page.url()).origin;
  const requests: string[] = [];
  const opens: Promise<string>[] = [];
  const onRequest = (r: Request) => {
    const line = requestLine(r, appOrigin);
    if (line) requests.push(line);
  };
  const onResponse = (r: Response) => {
    if (r.url().includes("/rest/v1/rpc/marking_unit_open")) opens.push(r.text());
  };
  page.on("request", onRequest);
  page.on("response", onResponse);
  const unitId = await nextOnScreen(page);
  await expect.poll(() => page.getByTestId("page-surface").locator("img").evaluate((i: HTMLImageElement) => (i.complete ? i.naturalWidth : 0))).toBeGreaterThan(0);
  await saved(page);
  await expect(screenHeader(page).getByText(/^Held for you until/)).toBeVisible();
  await page.waitForLoadState("networkidle");
  page.off("request", onRequest);
  page.off("response", onResponse);
  const answers = await Promise.all(opens);
  expect(answers.length).toBeGreaterThan(0);
  const { indexNumber } = await pieceOf(unitId);
  return {
    unitId,
    shape: await screenShape(page, indexNumber),
    requests: requests.sort(),
    openKeys: keyPaths(JSON.parse(answers[answers.length - 1])),
    // The kind of pass is the database's own business: only who holds it, how and for how long are compared.
    holds: (await holdsOn(unitId)).map(({ marker, how, ms }) => ({ marker, how, ms })),
  };
}

/** Marks the piece on the screen as the lead marked it, submits, and returns marking_submit's answer with the rev and
 * the totals as their kinds only. */
async function submitWatched(page: Page): Promise<Record<string, string>> {
  await giveMarks(page, LEAD_MARKS);
  const answer = page.waitForResponse((r) => r.url().includes("/rest/v1/rpc/marking_submit") && r.request().method() === "POST");
  await submit(page);
  const body = (await (await answer).json()) as Record<string, unknown>;
  await expect(page.getByText(SUBMITTED)).toBeVisible();
  return Object.fromEntries(Object.entries(body).map(([k, v]) => [k, k === "ok" || k === "feedback" ? JSON.stringify(v) : typeof v]));
}

/** The visible marking screen as structure and words: the header, the hold line and the tools as HTML, and the whole
 * screen as a skeleton (tags, classes, test ids, roles and labels) and as its text, with the index number, the times
 * and React's own element ids taken out (useId counts every component mounted since the page loaded, so it differs
 * between any two pieces opened one after the other). */
async function screenShape(page: Page, indexNumber: string): Promise<Watched["shape"]> {
  return page.evaluate((index) => {
    const norm = (s: string) =>
      s.split(index).join("<index>").replace(/\b\d{1,2}:\d{2}\b/g, "<time>").replace(/_r_[0-9a-z]+_/g, "<react-id>");
    const root = document.querySelector('[data-testid="page-surface"]')!.closest(".h-dvh")!;
    const keep = ["class", "data-testid", "role", "aria-label", "aria-expanded", "aria-pressed", "aria-checked", "aria-describedby", "disabled", "type", "data-annotation-kind"];
    const walk = (el: Element): string =>
      `<${el.tagName}${keep.map((a) => (el.hasAttribute(a) ? ` ${a}="${norm(el.getAttribute(a) ?? "")}"` : "")).join("")}>${[...el.children].map(walk).join("")}</${el.tagName}>`;
    const header = root.querySelector("header")!;
    const hold = [...header.querySelectorAll("p")].find((p) => p.textContent?.startsWith("Held for you until"));
    return {
      header: norm(header.outerHTML),
      hold: norm(hold?.textContent ?? ""),
      tools: norm(root.querySelector('[role="toolbar"]')!.outerHTML),
      skeleton: walk(root),
      text: norm((root as HTMLElement).innerText),
    };
  }, indexNumber);
}
