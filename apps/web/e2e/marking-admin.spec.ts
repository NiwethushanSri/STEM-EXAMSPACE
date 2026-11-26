import { expect, test, type Page } from "@playwright/test";
import { assertNoOwner, cleanup, clearLoginAttempts, countTestUsers, signInUI, svc } from "./admin";
import { clearMarker, pieceState, remaskStates, removeMarkingExam, seedStaffMarkingExam, setPaperHiddenAreas, type Login, type SeededScript } from "./marking";
import { requireProcessor, waitForDb } from "./scripts";

// The staff side of marking (Phase 3A Task 13) against the local stack and the running processing server (npm run
// e2e:local starts it). One exam with two verified home scripts, on the fixture copies A and B with the processing
// server's own pictures. In order: an admin enters the questions and sees the paper total, approves a corrector and
// makes them lead marker, sets a deadline and opens marking, assigns both scripts to the marker and takes one back; a
// hidden area is added to the paper (through the service helper) and the processing server makes the pages' marking
// pictures again, which puts the marker's piece on hold, and the lead marker releases it from /marking; an admin takes
// the script back on its script page and hands it back, and the marker has the piece again. No marking page shows a
// candidate's name, and no page scrolls sideways at 1440, 820 or 390 px wide. Every row and file is removed afterwards.

test.describe.configure({ mode: "serial" });
test.use({ viewport: { width: 1440, height: 900 } });

let seed: Awaited<ReturnType<typeof seedStaffMarkingExam>>;
/** Assigned to the marker and kept: it goes on hold, is released, taken back and handed back. */
let kept: SeededScript;
/** Assigned, then taken back from the marker. */
let freed: SeededScript;

test.beforeAll(async () => {
  test.setTimeout(180_000);
  await assertNoOwner();
  requireProcessor();
  seed = await seedStaffMarkingExam();
  [kept, freed] = seed.scripts;
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterAll(async () => {
  if (seed) await removeMarkingExam(seed.examId);
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

async function signIn(page: Page, who: Login): Promise<void> {
  await signInUI(page, who.email, who.password);
  await expect(page).not.toHaveURL(/\/login/);
}

/** The page has no sideways scroll at 1440, 820 and 390 px wide. Ends at 1440. */
async function noSidewaysScroll(page: Page, what: string): Promise<void> {
  for (const width of [1440, 820, 390]) {
    await page.setViewportSize({ width, height: 900 });
    await expect
      .poll(() => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth), { message: `${what} at ${width} px wide` })
      .toBeLessThanOrEqual(0);
  }
  await page.setViewportSize({ width: 1440, height: 900 });
}

/** Neither the page's text nor its markup holds a candidate's first or last name. */
async function noCandidateName(page: Page, what: string): Promise<void> {
  const text = await page.locator("body").innerText();
  const html = await page.content();
  for (const s of seed.scripts) {
    for (const name of [s.firstName, s.lastName]) {
      expect(text, `${what} shows ${name}`).not.toContain(name);
      expect(html, `${what} carries ${name}`).not.toContain(name);
    }
  }
}

const pieces = async () => Promise.all([pieceState(kept.scriptId), pieceState(freed.scriptId)]);

test("admin_enters_the_structure_and_sees_the_paper_total", async ({ page }) => {
  await signIn(page, seed.admin);
  await page.goto(`/admin/exams/${seed.examId}/structure`);
  await expect(page.getByTestId("paper-total")).toHaveText("Paper total: 0 marks");
  await page.getByRole("button", { name: "Add question" }).click();
  await page.getByLabel("Maximum mark of question 1").fill("5");
  await page.getByRole("button", { name: "Add question" }).click();
  await page.getByLabel("Maximum mark of question 2").fill("4");
  await expect(page.getByTestId("paper-total")).toHaveText("Paper total: 9 marks");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByText("Saved.", { exact: true })).toBeVisible();
  const questions = async () =>
    ((await svc().from("exam_questions").select("label, max_mark").eq("exam_id", seed.examId).order("position")).data ?? []).map((q) => `${q.label}: ${Number(q.max_mark)}`);
  expect(await questions()).toEqual(["1: 5", "2: 4"]);
  await page.reload();
  await expect(page.getByTestId("paper-total")).toHaveText("Paper total: 9 marks");
  await noSidewaysScroll(page, "the questions and mark scheme page");
});

test("admin_approves_a_corrector_and_makes_them_lead", async ({ page }) => {
  await signIn(page, seed.admin);
  await page.goto("/admin/marking/markers");
  const card = page.getByRole("region", { name: seed.lead.name, exact: true });
  await card.getByLabel("Approve for a subject").selectOption({ label: seed.subject });
  await card.getByRole("button", { name: "Approve", exact: true }).click();
  const approve = card.getByRole("group", { name: `Approve for ${seed.subject}` });
  await approve.getByLabel("Reason (kept in the audit log)").fill("Experienced corrector");
  await approve.getByRole("button", { name: "Confirm" }).click();
  await card.getByRole("button", { name: "Make lead marker" }).click();
  const lead = card.getByRole("group", { name: `Make lead marker for ${seed.subject}` });
  await lead.getByLabel("Reason (kept in the audit log)").fill("Leads this subject");
  await lead.getByRole("button", { name: "Confirm" }).click();
  await expect(card.getByText("Lead marker", { exact: true })).toBeVisible();
  expect((await svc().from("marker_approvals").select("lead").eq("marker_id", seed.lead.id)).data).toEqual([{ lead: true }]);
  await noSidewaysScroll(page, "the markers page");
});

test("admin_sets_a_deadline_and_opens_marking", async ({ page }) => {
  await signIn(page, seed.admin);
  await page.goto(`/admin/exams/${seed.examId}`);
  const panel = page.getByRole("region", { name: "Marking", exact: true });
  // 17:00 UK time a week from now.
  const day = new Date(Date.now() + 7 * 86_400_000).toLocaleDateString("en-CA", { timeZone: "Europe/London" });
  await panel.getByLabel("Deadline date").fill(day);
  await panel.getByLabel("Deadline time").fill("17:00");
  await panel.getByRole("button", { name: "Save settings" }).click();
  const deadline = async () => (await svc().from("exam_marking").select("deadline").eq("exam_id", seed.examId).maybeSingle()).data?.deadline ?? null;
  await expect.poll(deadline).not.toBeNull();
  const uk = (iso: string) => new Date(iso).toLocaleString("en-CA", { timeZone: "Europe/London", hour12: false, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
  expect(uk((await deadline())!)).toBe(`${day}, 17:00`);

  await panel.getByRole("button", { name: "Open marking" }).click();
  await page.getByRole("dialog", { name: "Open marking?" }).getByRole("button", { name: "Open marking" }).click();
  await expect(panel.getByTestId("marking-status")).toContainText("Open");
  expect((await pieces()).map((p) => p.state)).toEqual(["open", "open"]);
  await noSidewaysScroll(page, "the exam page");
});

test("admin_assigns_two_scripts_and_takes_one_back", async ({ page }) => {
  // Practice is on (the exam's default checks), so a marker gets live work only once cleared (3B Task 5): the lead
  // marker clears them, through the function, as their own page will.
  await clearMarker(seed.lead, seed.examId, seed.marker.id);
  await signIn(page, seed.admin);
  await page.goto(`/admin/marking?exam=${seed.examId}`);
  const scripts = page.getByRole("region", { name: `Scripts: ${seed.title} (Paper 1)`, exact: true });
  await expect(scripts.getByTestId("marking-unit")).toHaveCount(2);

  await scripts.getByLabel("Tick every script shown").check();
  await scripts.getByRole("button", { name: "Assign to…", exact: true }).click();
  const assign = page.getByRole("dialog", { name: "Assign 2 scripts" });
  await assign.getByLabel("Marker").selectOption({ label: seed.marker.name });
  await assign.getByLabel("Reason").fill("Start of marking");
  await assign.getByRole("button", { name: "Assign", exact: true }).click();
  await expect(assign).toBeHidden();
  await expect.poll(async () => (await pieces()).map((p) => `${p.state} ${p.how} ${p.holder === seed.marker.id}`)).toEqual(["taken assigned true", "taken assigned true"]);
  await expect(scripts.getByTestId("marking-unit").filter({ hasText: seed.marker.name })).toHaveCount(2);

  await scripts.getByLabel(`Tick script ${freed.scriptNumber}`).check();
  await scripts.getByRole("button", { name: "Take back", exact: true }).click();
  const takeBack = page.getByRole("dialog", { name: "Take back 1 script" });
  await takeBack.getByLabel("Reason").fill("Another marker will take it");
  await takeBack.getByRole("button", { name: "Take back", exact: true }).click();
  await expect(takeBack).toBeHidden();
  await expect.poll(async () => (await pieces()).map((p) => `${p.state} ${p.how}`)).toEqual(["taken assigned", "open null"]);
  await expect(scripts.getByTestId("marking-unit").filter({ hasText: seed.marker.name })).toHaveCount(1);
  await noCandidateName(page, "the admin marking page");
  await noSidewaysScroll(page, "the admin marking page");

  // The admin home page has the exam's marking row: 2 left, none marked, checked, with the lead marker or waiting for a
  // second marker (3B), none on hold, the deadline.
  await page.goto("/admin");
  const row = page.getByTestId("marking-exam").filter({ hasText: seed.title });
  await expect(row.getByRole("cell")).toHaveText(["2", "0", "0", "0", "0", "0", /^Mark by /]);
  await noSidewaysScroll(page, "the admin home page");
});

test("a_hidden_area_change_puts_the_marked_piece_on_hold", async ({ page }) => {
  test.setTimeout(300_000);
  // A hidden area added to page 2 of the paper: the processing server makes both files' marking pictures again.
  expect(await setPaperHiddenAreas(seed.admin, seed.paperId, [{ page: 2, x: 0.55, y: 0.85, w: 0.35, h: 0.1 }])).toBe(2);
  await waitForDb(() => remaskStates(seed.examId), ["done", "done"], "the processing server makes the marking pictures again");
  // The piece the marker holds goes on hold; the free one does not.
  await waitForDb(async () => (await pieces()).map((p) => `${p.onHold} ${p.holdReason}`), ["true picture_changed", "false null"], "the held piece is on hold");

  // The admin home page says so.
  await signIn(page, seed.admin);
  await page.goto("/admin");
  await expect(page.getByTestId("marking-exam").filter({ hasText: seed.title }).getByRole("cell")).toHaveText(["2", "0", "0", "0", "0", "1", /^Mark by /]);
  await expect(page.getByTestId("marking-alerts")).toContainText(/\d+ scripts? (is|are) on hold in marking\./);

  // The exam's progress card offers "Release all": it needs only the exam, so it is there when the alerts list is not.
  // (The lead releases the piece in the next test, so the box is only opened and closed here.)
  await page.goto(`/admin/marking?exam=${seed.examId}`);
  const progress = page.getByRole("region", { name: "Progress", exact: true });
  await progress.getByTestId("progress-exam").filter({ hasText: seed.title }).getByRole("button", { name: `Release all for ${seed.title}` }).click();
  const all = page.getByRole("dialog", { name: `Release all for ${seed.title}` });
  await expect(all).toContainText("Every changed picture of this exam that can be released now is released. The others stay open.");
  await expect(all.getByLabel("Reason")).toBeVisible();
  await all.getByRole("button", { name: "Cancel" }).click();
  await expect(all).toHaveCount(0);
  expect((await pieces()).map((p) => `${p.onHold} ${p.holdReason}`)).toEqual(["true picture_changed", "false null"]);
});

test("the_lead_marker_releases_the_piece_from_marking", async ({ page }) => {
  await signIn(page, seed.lead);
  await page.goto("/marking");
  const attention = page.getByRole("region", { name: "Needs your attention", exact: true });
  const release = attention.getByRole("button", { name: `Release script ${kept.scriptNumber}` });
  await release.click();
  const dialog = page.getByRole("dialog", { name: `Release script ${kept.scriptNumber}` });
  await dialog.getByLabel("Reason").fill("The new pictures are fine");
  await dialog.getByRole("button", { name: "Release", exact: true }).click();
  await expect(dialog).toBeHidden();
  await expect(release).toHaveCount(0);
  await expect.poll(async () => (await pieces()).map((p) => `${p.onHold} ${p.holder === seed.marker.id}`)).toEqual(["false true", "false false"]);
  await noCandidateName(page, "the lead marker's marking page");
  await noSidewaysScroll(page, "the lead marker's marking page");
});

test("admin_takes_the_script_back_and_hands_it_back", async ({ page }) => {
  await signIn(page, seed.admin);
  await page.goto(`/admin/scripts/${kept.scriptId}`);
  const card = page.getByRole("region", { name: "Marking", exact: true });
  await card.getByLabel(/^Reason/).fill("Look at the pages again");
  await card.getByRole("button", { name: "Take back from markers" }).click();
  await expect(card).toContainText("Taken back from the markers on");
  await expect.poll(async () => (await pieces())[0]).toMatchObject({ onHold: true, holdReason: "taken_back", holder: seed.marker.id });

  // Once the script is verified again it can be handed back, and the piece returns to its marker.
  const handBack = card.getByRole("button", { name: "Hand back to markers" });
  await expect(handBack).toBeEnabled();
  await handBack.click();
  await expect(card).toContainText("This script is being marked.");
  await expect.poll(async () => (await pieces())[0]).toMatchObject({ state: "taken", onHold: false, holdReason: null, holder: seed.marker.id, how: "assigned" });
  await noSidewaysScroll(page, "the script page");
});

test("the_marker_has_the_script_again", async ({ page }) => {
  await signIn(page, seed.marker);
  await page.goto("/marking");
  await expect(page.getByTestId("marking-piece")).toHaveCount(1);
  const piece = page.getByTestId("marking-piece").filter({ hasText: `Script ${kept.scriptNumber}` });
  await expect(piece).toContainText("In progress");
  await expect(piece).toContainText("Assigned to you");
  await expect(piece.getByRole("link", { name: `Open script ${kept.scriptNumber}` })).toBeVisible();
  await noCandidateName(page, "the marker's marking page");
  await noSidewaysScroll(page, "the marker's marking page");
});
