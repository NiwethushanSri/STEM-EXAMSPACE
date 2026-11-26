import { readFileSync } from "node:fs";
import { expect, test, type Page } from "@playwright/test";
import { assertNoOwner, cleanup, clearLoginAttempts, countTestUsers, signInUI, svc } from "./admin";
import {
  LEAD_MARKS,
  QUESTIONS,
  annotationKinds,
  assignAs,
  changeAs,
  checkStateOf,
  markAs,
  nextAs,
  removeMarkingExam,
  seedChecksExam,
  seedNext,
  unitsOf,
  withdrawApprovalIfAny,
  type Login,
} from "./marking";

// The staff side of the checks on the marking (Phase 3B Task 13), against the local stack, with the Edge Functions
// served (the marking screen's and the review screen's pictures come from marking-pictures; npm run e2e:local starts
// them). One exam of five verified home scripts (s1 to s5, in script order) with double marking and seeded scripts on,
// two markers (A: "Marker Tester", B: "Marker2 Tester") and a lead marker. In order:
//   - an admin sets double marking to every script and opens marking;
//   - A marks s1 and s2; B is handed s1's second marking and sees none of A's marks, and gives other marks; B
//     second-marks s2 the same, and first-marks s4, which A second-marks the same;
//   - the lead finds s1 under "Marks that differ", looks at both markers' marks on the page, and presses "Second marks
//     stand" with a reason: s1 is checked;
//   - the lead marks s3, makes it a seeded script, and once A has had it through Next script sees one attempt counted;
//   - the lead takes a sample of A's work, sends s2 back to A with a note, and A reads the note and submits again;
//   - an admin cannot turn double marking off while the subject has more than one approved marker; once A and B are no
//     longer approved (the lead counts as one), the admin turns it off with a reason, and the approval page shows the
//     reason with who and when; the lead marks s5, which is checked at once;
//   - with every script checked the admin approves the exam's marking, and a marker's change is then refused;
//   - the admin sets a pay rate, the payments page shows the month's lines, and the CSV's first line is its header.
// No page shows a candidate's name, and none scrolls sideways at 1,440, 820 or 390 px wide. Every row and file is
// removed afterwards.

test.describe.configure({ mode: "serial" });
test.use({ viewport: { width: 1440, height: 900 } });

let seed: Awaited<ReturnType<typeof seedChecksExam>>;
let A: Login;
let B: Login;
/** The pieces s1 to s5 (one per script), with their script numbers, once marking is open. */
let s: { unitId: string; scriptNumber: string }[] = [];
const NOTE = "Look at question 3 again: the units are missing.";
const OFF_REASON = "Only the lead marks this subject now.";
const SUBMITTED = "Submitted. You can still change it until marking closes.";
const CSV_HEADER = "Month,Marker,Exam,Paper,Question group,Kind,Scripts,Rate (£),Amount (£),Fixed";

test.beforeAll(async () => {
  test.setTimeout(180_000);
  await assertNoOwner();
  seed = await seedChecksExam({ scripts: 5, checks: { double_marking: true, sample_percent: 10, seeds: true, seed_every: 10, practice: false } });
  [A, B] = seed.markers;
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterAll(async () => {
  if (seed) {
    await withdrawApprovalIfAny(seed.admin, seed.examId);
    await removeMarkingExam(seed.examId);
  }
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

/** Signs in as `who`, ending any session the page had (several people use one page in a test). */
async function signIn(page: Page, who: Login): Promise<void> {
  await page.context().clearCookies();
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
  for (const st of seed.students) {
    for (const name of [st.firstName, st.lastName]) {
      expect(text, `${what} shows ${name}`).not.toContain(name);
      expect(html, `${what} carries ${name}`).not.toContain(name);
    }
  }
}

/** Gives each question its mark with the mark buttons, in paper order, and waits for the save. */
async function giveMarks(page: Page, marks: readonly number[]): Promise<void> {
  for (const [i, m] of marks.entries()) {
    await page.getByTestId(`question-${QUESTIONS[i].label}`).click();
    await page.getByRole("button", { name: `${m} ${m === 1 ? "mark" : "marks"}`, exact: true }).click();
  }
  await expect(page.getByTestId("save-status")).toHaveText("Saved");
}

const ukDay = (d: Date) => new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", day: "numeric", month: "long", year: "numeric" }).format(d);
const ukMonth = (d: Date) => new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/London", year: "numeric", month: "2-digit" }).format(d);
const markingPanel = (page: Page) => page.getByRole("region", { name: "Marking", exact: true });

test("admin_sets_double_marking_to_every_script_and_opens_marking", async ({ page }) => {
  await signIn(page, seed.admin);
  await page.goto(`/admin/exams/${seed.examId}`);
  const checks = markingPanel(page).getByRole("form", { name: "Checks on the marking" });
  // The first number box is the share of scripts second-marked.
  await checks.getByRole("spinbutton").first().fill("100");
  await checks.getByRole("button", { name: "Save checks" }).click();
  await expect.poll(async () => (await svc().from("exam_marking").select("sample_percent").eq("exam_id", seed.examId).single()).data?.sample_percent).toBe(100);

  await markingPanel(page).getByRole("button", { name: "Open marking" }).click();
  await page.getByRole("dialog", { name: "Open marking?" }).getByRole("button", { name: "Open marking" }).click();
  await expect(markingPanel(page).getByTestId("marking-status")).toContainText("Open");
  await expect.poll(async () => (await unitsOf(seed.examId)).length).toBe(5);
  s = await unitsOf(seed.examId);
  await noSidewaysScroll(page, "the exam page");
});

test("marker_b_is_handed_a_marked_script_and_sees_none_of_its_marks", async ({ page }) => {
  test.setTimeout(180_000);
  // A marks s1 (with a tick on its first page) and s2; every script is second-marked, so both wait for a second marker.
  await assignAs(seed.admin, [s[0].unitId, s[1].unitId], A);
  await markAs(A, s[0].unitId, [5, 4, 15], { tick: true, note: "Full marks, I think." });
  await markAs(A, s[1].unitId, [1, 1, 1]);
  expect(await annotationKinds(s[0].unitId)).toEqual(["tick"]);
  expect([await checkStateOf(s[0].unitId), await checkStateOf(s[1].unitId)]).toEqual(["waiting_second", "waiting_second"]);

  // B is handed s1's second marking, and opens it from their list: no marks, no tick, no note, a total of 0.
  await assignAs(seed.admin, [s[0].unitId], B, "second");
  await signIn(page, B);
  await page.goto("/marking");
  await page.getByRole("link", { name: `Open script ${s[0].scriptNumber}` }).click();
  await page.waitForURL((u) => u.pathname.endsWith(s[0].unitId));
  await expect(page.getByTestId("page-surface").locator("img")).toBeVisible();
  await expect(page.locator("[data-annotation-kind]")).toHaveCount(0);
  for (const q of QUESTIONS) await expect(page.getByTestId(`question-${q.label}-mark`)).toHaveText("–");
  await expect(page.getByTestId("running-total")).toHaveText("0 / 24");
  await expect(page.getByLabel("Private note to the lead marker")).toHaveValue("");
  expect(await page.content()).not.toContain("Full marks, I think.");
  await noCandidateName(page, "the second marker's screen");

  // B's marks differ from A's by more than the tolerance: s1 goes to the lead marker.
  await giveMarks(page, [1, 1, 1]);
  await page.getByRole("button", { name: "Submit", exact: true }).click();
  await expect(page.getByText(SUBMITTED)).toBeVisible();
  await expect.poll(() => checkStateOf(s[0].unitId)).toBe("to_lead");

  // s2: B's second marks agree with A's (checked). s4: B marks it first and A second, the same (checked).
  await assignAs(seed.admin, [s[1].unitId], B, "second");
  await markAs(B, s[1].unitId, [1, 1, 1]);
  await assignAs(seed.admin, [s[3].unitId], B);
  await markAs(B, s[3].unitId, [1, 1, 1]);
  await assignAs(seed.admin, [s[3].unitId], A, "second");
  await markAs(A, s[3].unitId, [1, 1, 1]);
  expect([await checkStateOf(s[1].unitId), await checkStateOf(s[3].unitId)]).toEqual(["checked", "checked"]);
});

test("lead_settles_the_marks_that_differ", async ({ page }) => {
  await signIn(page, seed.lead);
  await page.goto(`/marking/review?tab=difference&exam=${seed.examId}`);
  await expect(page.getByRole("link", { name: "Marks that differ (1)" })).toBeVisible();
  await noCandidateName(page, "the review page");
  await noSidewaysScroll(page, "the review page");
  await page.getByRole("link", { name: `Open script ${s[0].scriptNumber}` }).click();
  await page.waitForURL(/\/marking\/review\/[0-9a-f-]{36}/);

  // Both markers' marks on the page: A's tick, and nothing of B's; and the questions that differ.
  await page.getByText("First marker's marks", { exact: true }).click();
  await expect(page.locator("[data-annotation-kind]")).toHaveCount(1);
  await page.getByText("Second marker's marks", { exact: true }).click();
  await expect(page.locator("[data-annotation-kind]")).toHaveCount(0);
  await expect(page.getByTestId("review-row").filter({ hasText: "Different" })).toHaveCount(3);
  await expect(page.getByTestId("review-first-total")).toHaveText("24");
  await expect(page.getByTestId("review-second-total")).toHaveText("3");
  await noCandidateName(page, "the review screen");
  await noSidewaysScroll(page, "the review screen");

  await page.getByRole("button", { name: "Second marks stand", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "Second marks stand" });
  await dialog.getByLabel("Reason").fill("Question 3 has no units");
  await dialog.getByRole("button", { name: "Second marks stand", exact: true }).click();
  await expect(page.getByText("Settled. The second marks stand.")).toBeVisible();
  await expect.poll(() => checkStateOf(s[0].unitId)).toBe("checked");
});

test("lead_marks_a_script_makes_it_a_seeded_script_and_sees_an_attempt", async ({ page }) => {
  test.setTimeout(180_000);
  await assignAs(seed.admin, [s[2].unitId], seed.lead);
  await markAs(seed.lead, s[2].unitId, [...LEAD_MARKS]);

  await signIn(page, seed.lead);
  await page.goto(`/marking/review?tab=standards&exam=${seed.examId}`);
  await page.getByTestId("standard-candidate").filter({ hasText: s[2].scriptNumber }).getByRole("button", { name: "Use as a seeded script" }).click();
  const dialog = page.getByRole("dialog", { name: `Use script ${s[2].scriptNumber} as a seeded script` });
  await dialog.getByRole("button", { name: "Use as a seeded script" }).click();
  const standard = page.getByTestId("standard").filter({ hasText: s[2].scriptNumber });
  await expect(standard).toContainText("0 attempts, 0 outside the tolerance");
  // A seeded script is never second-marked: it is checked on the lead's marks.
  await expect.poll(() => checkStateOf(s[2].unitId)).toBe("checked");

  // A meets it through Next script and marks it as the lead did.
  await seedNext(seed.examId, A.id);
  expect(await nextAs(A, seed.examId)).toBe(s[2].unitId);
  await markAs(A, s[2].unitId, [...LEAD_MARKS]);
  await page.reload();
  await expect(standard).toContainText("1 attempt, 0 outside the tolerance");
  await noCandidateName(page, "the practice and seeded scripts");
  await noSidewaysScroll(page, "the practice and seeded scripts");
});

test("lead_sends_a_checked_script_back_and_the_marker_reads_the_note", async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, seed.lead);
  await page.goto(`/marking/review?tab=markers&exam=${seed.examId}`);
  // s2 is the only piece of A's own marking with no review: the sample takes it.
  await page
    .getByTestId("exam-marker")
    .filter({ has: page.getByText("Marker Tester", { exact: true }) })
    .getByRole("button", { name: "Review 5 of their scripts" })
    .click();
  await expect(page.getByText("1 script added to your sample.")).toBeVisible();
  await page.goto(`/marking/review?tab=sample&exam=${seed.examId}`);
  await page.getByRole("link", { name: `Open script ${s[1].scriptNumber}` }).click();
  await page.waitForURL(/\/marking\/review\/[0-9a-f-]{36}/);
  await page.getByRole("button", { name: "Send back", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "Send back" });
  await expect(dialog.getByLabel("To the same marker (Marker Tester)")).toBeChecked();
  await dialog.getByLabel("Note to the marker").fill(NOTE);
  await dialog.getByLabel("Reason").fill("A routine look");
  await dialog.getByRole("button", { name: "Send back", exact: true }).click();
  await expect(page.getByText("Sent back to the same marker.", { exact: true })).toBeVisible();

  // A reads it on their list and on the script, and submits again, within the tolerance of B's second marks.
  await signIn(page, A);
  await page.goto("/marking");
  const piece = page.getByTestId("marking-piece").filter({ hasText: `Script ${s[1].scriptNumber}` });
  await expect(piece).toContainText("Sent back by the lead marker.");
  await noCandidateName(page, "the marker's list");
  await piece.getByRole("link", { name: `Open script ${s[1].scriptNumber}` }).click();
  await page.waitForURL((u) => u.pathname.endsWith(s[1].unitId));
  await expect(page.getByTestId("sent-back-note")).toHaveText(`The lead marker sent this back: ${NOTE}`);
  // Their marks are still there (1, 1, 1): question 3 becomes 2.
  await page.getByTestId("question-3").click();
  await page.getByRole("button", { name: "2 marks", exact: true }).click();
  await expect(page.getByTestId("save-status")).toHaveText("Saved");
  await page.getByRole("button", { name: "Submit", exact: true }).click();
  await expect(page.getByText(SUBMITTED)).toBeVisible();
  await expect.poll(() => checkStateOf(s[1].unitId)).toBe("checked");
});

test("admin_turns_double_marking_off_only_when_one_marker_is_left", async ({ page }) => {
  test.setTimeout(180_000);
  await signIn(page, seed.admin);
  await page.goto(`/admin/exams/${seed.examId}`);
  // Refused while the subject has more than one approved marker: the switch cannot be turned off.
  await expect(markingPanel(page).getByLabel("Double marking")).toBeDisabled();
  await expect(markingPanel(page).getByText("These checks can only be turned off when the subject has one approved marker.")).toBeVisible();

  // A and B are no longer approved for the subject; the lead is the one approved marker left.
  await page.goto("/admin/marking/markers");
  for (const name of ["Marker2 Tester", "Marker Tester"]) {
    const card = page.getByRole("region", { name, exact: true });
    await card.getByRole("button", { name: "Remove approval" }).click();
    const step = card.getByRole("group", { name: `Remove approval for ${seed.subject}` });
    await step.getByLabel("Reason (kept in the audit log)").fill("No longer marks this subject");
    await step.getByRole("button", { name: "Confirm" }).click();
    await expect(card.getByText("Not approved to mark any subject.")).toBeVisible();
  }

  await page.goto(`/admin/exams/${seed.examId}`);
  const checks = markingPanel(page).getByRole("form", { name: "Checks on the marking" });
  await checks.getByLabel("Double marking").uncheck();
  await checks.getByRole("button", { name: "Save checks" }).click();
  const dialog = page.getByRole("dialog", { name: "Turn checks off?" });
  await dialog.getByLabel("Reason").fill(OFF_REASON);
  await dialog.getByRole("button", { name: "Save checks" }).click();
  await expect(dialog).toBeHidden();
  await expect.poll(async () => (await svc().from("exam_marking").select("double_marking").eq("exam_id", seed.examId).single()).data?.double_marking).toBe(false);

  // The lead marks s5: with double marking off it is checked at once.
  await assignAs(seed.admin, [s[4].unitId], seed.lead);
  await markAs(seed.lead, s[4].unitId, [...LEAD_MARKS]);
  expect(await checkStateOf(s[4].unitId)).toBe("checked");

  // The admin's list of scripts says each is checked; s1's was settled by the lead.
  await page.goto(`/admin/marking?exam=${seed.examId}`);
  const scripts = page.getByRole("region", { name: `Scripts: ${seed.title} (Paper 1)`, exact: true });
  await expect(scripts.getByTestId("marking-unit").filter({ hasText: s[0].scriptNumber })).toContainText("Checked");
  await expect(scripts.getByTestId("marking-unit").filter({ hasText: "Checked" })).toHaveCount(5);
  await noCandidateName(page, "the admin marking page");
  await noSidewaysScroll(page, "the admin marking page");

  // The approval page shows the reason, who turned the checks off and when.
  await page.goto(`/admin/marking/${seed.examId}/approval`);
  await expect(page.getByTestId("checks-turned-off")).toContainText(`Turned off by Casey Tester on ${ukDay(new Date())}: ${OFF_REASON}`);
  await noCandidateName(page, "the approval page");
  await noSidewaysScroll(page, "the approval page");
});

test("admin_approves_the_marking_and_a_change_is_then_refused", async ({ page }) => {
  await signIn(page, seed.admin);
  await page.goto(`/admin/marking/${seed.examId}/approval`);
  await page.getByRole("button", { name: "Approve this exam's marking" }).click();
  const dialog = page.getByRole("dialog", { name: "Approve this exam's marking?" });
  await dialog.getByRole("button", { name: "Approve this exam's marking" }).click();
  await expect(page.getByTestId("approved-by")).toContainText("Approved by Casey Tester");
  await expect.poll(async () => (await svc().from("exam_marking").select("approved_at").eq("exam_id", seed.examId).single()).data?.approved_at).not.toBeNull();
  await noCandidateName(page, "the approved exam's approval page");

  // The marker statistics show no candidate either.
  await page.goto(`/admin/marking/${seed.examId}/statistics`);
  await noCandidateName(page, "the statistics page");
  await noSidewaysScroll(page, "the statistics page");

  // A change to a marked script is refused: approval closed marking. The lead's screen opens it read only.
  expect(await changeAs(seed.lead, s[4].unitId, [0, 0, 0])).toBe("marking_closed");
  await signIn(page, seed.lead);
  await page.goto(`/marking/${s[4].unitId}`);
  await expect(page.getByTestId("save-status")).toHaveText("Read only");
  await expect(page.getByText("Marking has closed for this exam, so its pages can no longer be shown.")).toBeVisible();
});

test("admin_sets_a_pay_rate_and_downloads_the_month", async ({ page }) => {
  await signIn(page, seed.admin);
  await page.goto(`/admin/exams/${seed.examId}`);
  const pay = markingPanel(page).getByRole("form", { name: "Marker pay" });
  await pay.getByLabel("Pay per script").fill("12.50");
  await pay.getByRole("button", { name: "Save pay rates" }).click();
  await expect.poll(async () => (await svc().from("marker_rates").select("pence").eq("exam_id", seed.examId)).data).toEqual([{ pence: 1250 }]);

  await page.goto(`/admin/marking/payments?month=${ukMonth(new Date())}`);
  // A's first markings and second marking, B's second markings and first marking, and the lead's own; never the seed.
  const a = page.getByRole("region", { name: "Marker Tester", exact: true });
  const b = page.getByRole("region", { name: "Marker2 Tester", exact: true });
  for (const line of [a, b]) {
    await expect(line).toContainText("First marking");
    await expect(line).toContainText("Second marking");
  }
  await expect(page.getByRole("region", { name: "Lead Tester", exact: true })).toContainText("First marking");
  await noCandidateName(page, "the payments page");
  await noSidewaysScroll(page, "the payments page");

  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Download CSV" }).click();
  const csv = readFileSync((await (await download).path())!, "utf8").replace(/^﻿/, "");
  expect(csv.split("\r\n")[0]).toBe(CSV_HEADER);
  for (const st of seed.students) {
    expect(csv).not.toContain(st.firstName);
    expect(csv).not.toContain(st.lastName);
  }
});
