import { expect, test, type Page } from "@playwright/test";
import {
  BASE,
  assertNoOwner,
  cleanup,
  clearLoginAttempts,
  countTestUsers,
  createAccount,
  signInUI,
  svc,
  type TestAccount,
} from "./admin";

// Staff exam and venue pages. Serial. Every row it creates (subjects, venues, exams, bookings, users) is removed again.

const tag = crypto.randomUUID().slice(0, 8);
const SUBJECT = `E2E Subject ${tag}`;
const SUBJECT_B = `E2E Subject ${tag} B`;
const VENUE = `E2E Venue ${tag}`;
const SECRET_PRICE = "£15.00";

// Dates come from the clock: next year's first Saturday of June (BST) and of December (GMT).
const Y = new Date().getUTCFullYear() + 1;
function firstSaturday(month0: number): Date {
  const d = new Date(Date.UTC(Y, month0, 1, 12));
  while (d.getUTCDay() !== 6) d.setUTCDate(d.getUTCDate() + 1);
  return d;
}
const SUMMER = firstSaturday(5);
const WINTER = firstSaturday(11);
const ymd = (d: Date) => d.toISOString().slice(0, 10);
const DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
/** Expected London display of a calendar date at the given London wall-clock time. */
const label = (d: Date, hhmm: string) => `${DAY_NAMES[d.getUTCDay()]} ${d.getUTCDate()} ${MONTH_NAMES[d.getUTCMonth()]} ${d.getUTCFullYear()}, ${hhmm}`;
const daysBefore = (d: Date, n: number) => new Date(d.getTime() - n * 86400_000);
const inDays = (n: number) => new Date(Date.now() + n * 86400_000).toISOString();

let adminId: string;
let admin: TestAccount;
let subjectId: number;
let subjectBId: number;
let venueId: string;

async function makeExam(o: {
  title: string;
  subject?: number;
  status?: "draft" | "published";
  seats?: number;
  price?: number;
  confirmed?: boolean;
  starts?: string;
  by?: string;
}): Promise<string> {
  const starts = o.starts ?? inDays(40);
  const { data, error } = await svc()
    .from("exams")
    .insert({
      subject_id: o.subject ?? subjectId,
      title: `${tag} ${o.title}`,
      paper: "Paper 1",
      format: "in_person",
      venue_id: venueId,
      room: "Hall A",
      starts_at: starts,
      duration_minutes: 90,
      seat_limit: o.seats ?? 10,
      price_pence: o.price ?? 1500,
      price_confirmed: o.confirmed ?? true,
      booking_deadline: new Date(Date.parse(starts) - 3 * 86400_000).toISOString(),
      status: o.status ?? "published",
      created_by: o.by ?? adminId,
    })
    .select("id")
    .single();
  if (error || !data) throw new Error(`exam insert failed: ${error?.message}`);
  return data.id;
}

async function insertBooking(examId: string, studentId: string, status: "awaiting_payment" | "paid", amount = 1500) {
  const { error } = await svc().from("bookings").insert({ exam_id: examId, student_id: studentId, booked_by: studentId, status, amount_pence: amount });
  if (error) throw new Error(`booking insert failed: ${error.message}`);
}

async function exam(title: string) {
  const { data } = await svc().from("exams").select("*").eq("title", `${tag} ${title}`).maybeSingle();
  return data;
}

async function bookingOf(examId: string, studentId: string) {
  const { data } = await svc().from("bookings").select("status, refund_due").eq("exam_id", examId).eq("student_id", studentId).maybeSingle();
  return data;
}

async function removeData() {
  const { data } = await svc().from("exams").select("id").like("title", `${tag}%`);
  const ids = (data ?? []).map((e) => e.id);
  if (ids.length) {
    await svc().from("bookings").delete().in("exam_id", ids);
    await svc().from("exams").delete().in("id", ids);
  }
}

const row = (p: Page, title: string) => p.getByTestId("exam-row").filter({ hasText: `${tag} ${title}` });

async function signInAdmin(page: Page) {
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
}

test.beforeAll(async () => {
  await assertNoOwner();
  admin = await createAccount({ role: "admin" });
  adminId = admin.id;
  const s = await svc().from("subjects").insert({ name: SUBJECT, kind: "school" }).select("id").single();
  const sb = await svc().from("subjects").insert({ name: SUBJECT_B, kind: "school" }).select("id").single();
  if (s.error || !s.data || sb.error || !sb.data) throw new Error(`subject insert failed: ${s.error?.message ?? sb.error?.message}`);
  subjectId = s.data.id;
  subjectBId = sb.data.id;
  const v = await svc().from("venues").insert({ name: VENUE, rooms: ["Hall A", "Hall B"] }).select("id").single();
  if (v.error || !v.data) throw new Error(`venue insert failed: ${v.error?.message}`);
  venueId = v.data.id;
  for (const path of ["/login", "/admin/exams", "/admin/venues", "/teacher/exams", "/owner"]) {
    await fetch(`${BASE}${path}`, { redirect: "manual" }).catch(() => undefined);
  }
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterEach(async () => {
  await removeData();
});
test.afterAll(async () => {
  await removeData();
  await svc().from("venues").delete().like("name", `${VENUE}%`);
  await svc().from("subjects").delete().like("name", `E2E Subject ${tag}%`);
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

test("admin_creates_in_person_exam_publishes_and_edits_the_date_in_london_time", async ({ page }) => {
  await signInAdmin(page);
  await page.goto("/admin/exams");
  await expect(page.getByRole("heading", { name: "Exams", exact: true })).toBeVisible();
  await expect(page.getByText("Preview — sample data")).toHaveCount(0);

  await page.getByRole("button", { name: "New exam" }).click();
  const form = page.getByRole("form", { name: "New exam" });
  await form.getByLabel("Subject", { exact: true }).selectOption({ label: SUBJECT });
  await form.getByLabel("Title").fill(`${tag} In person`);
  await form.getByLabel("Paper (optional)").fill("Paper 2");
  await form.getByLabel("Venue", { exact: true }).selectOption({ label: VENUE });
  await form.getByLabel("Room", { exact: true }).selectOption("Hall B");
  await form.getByLabel("Exam date (UK time)").fill(ymd(SUMMER));
  await form.getByLabel("Start time (UK time)").fill("10:30");
  await form.getByLabel("Duration (minutes)").fill("120");
  await form.getByLabel("Booking deadline date").fill(ymd(daysBefore(SUMMER, 3)));
  await form.getByLabel("Booking deadline time").fill("17:00");
  await form.getByLabel("Seat limit").fill("20");
  await form.getByLabel("Price (£)").fill("12.50");
  await form.getByRole("button", { name: "Create exam" }).click();
  await expect(page.getByRole("status")).toContainText("Exam created as a draft");

  const r = row(page, "In person");
  await expect(r).toContainText("Draft");
  await expect(r).toContainText(label(SUMMER, "10:30"));
  await expect(r).toContainText("£12.50");
  await expect(r).toContainText("0 / 20");
  await expect(r).toContainText(`${VENUE} · Hall B`);
  const created = await exam("In person");
  expect(created?.status).toBe("draft");
  expect(created?.price_pence).toBe(1250);
  expect(created?.price_confirmed).toBe(true);
  expect(created?.created_by).toBe(adminId);
  // 10:30 on a June date is BST, so 09:30 UTC.
  expect(created?.starts_at).toBe(`${ymd(SUMMER)}T09:30:00+00:00`);
  expect(created?.booking_deadline).toBe(`${ymd(daysBefore(SUMMER, 3))}T16:00:00+00:00`);

  // Publish behind a confirm step.
  await r.getByRole("button", { name: "Publish" }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Cancel" }).click();
  await expect.poll(async () => (await exam("In person"))?.status).toBe("draft");
  await r.getByRole("button", { name: "Publish" }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Publish exam" }).click();
  await expect(page.getByRole("status")).toContainText("Exam published");
  await expect(r).toContainText("Published");
  expect((await exam("In person"))?.status).toBe("published");

  // Move it to a winter date: 14:00 is GMT, so 14:00 UTC.
  await r.getByRole("button", { name: "Edit" }).click();
  const edit = page.getByRole("form", { name: "Edit exam" });
  await edit.getByLabel("Exam date (UK time)").fill(ymd(WINTER));
  await edit.getByLabel("Start time (UK time)").fill("14:00");
  await edit.getByRole("button", { name: "Save exam" }).click();
  await expect(page.getByRole("status")).toContainText("Exam saved");
  await expect(r).toContainText(label(WINTER, "14:00"));
  expect((await exam("In person"))?.starts_at).toBe(`${ymd(WINTER)}T14:00:00+00:00`);
  const { count } = await svc().from("audit_log").select("*", { count: "exact", head: true }).eq("target_id", created!.id).eq("action", "exam_updated");
  expect(count).toBe(1);
});

test("admin_creates_an_online_free_exam_and_bad_money_is_refused", async ({ page }) => {
  await signInAdmin(page);
  await page.goto("/admin/exams");
  await page.getByRole("button", { name: "New exam" }).click();
  const form = page.getByRole("form", { name: "New exam" });
  await form.getByLabel("Subject", { exact: true }).selectOption({ label: SUBJECT });
  await form.getByLabel("Title").fill(`${tag} Online`);
  await form.getByLabel("Format").selectOption("online");
  await expect(form.getByLabel("Venue", { exact: true })).toHaveCount(0);
  await form.getByLabel("Exam date (UK time)").fill(ymd(WINTER));
  await form.getByLabel("Start time (UK time)").fill("09:00");
  await form.getByLabel("Booking deadline date").fill(ymd(daysBefore(WINTER, 2)));
  await form.getByLabel("Seat limit").fill("50");

  for (const bad of ["-5", "1.234", "abc"]) {
    await form.getByLabel("Price (£)").fill(bad);
    await form.getByRole("button", { name: "Create exam" }).click();
    await expect(form.getByRole("alert")).toContainText("Enter the price in pounds");
  }
  expect(await exam("Online")).toBeNull();

  await form.getByLabel("Price (£)").fill("0");
  await form.getByRole("button", { name: "Create exam" }).click();
  await expect(page.getByRole("status")).toContainText("Exam created as a draft");
  const r = row(page, "Online");
  await expect(r).toContainText("Online");
  await expect(r).toContainText("Free");
  await expect(r).toContainText(label(WINTER, "09:00"));
  const created = await exam("Online");
  expect(created).toMatchObject({ format: "online", venue_id: null, room: null, price_pence: 0, status: "draft" });
  expect(created?.starts_at).toBe(`${ymd(WINTER)}T09:00:00+00:00`);

  await r.getByRole("button", { name: "Publish" }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Publish exam" }).click();
  await expect(r).toContainText("Published");
});

test("admin_cannot_lower_the_seat_limit_below_bookings_or_change_a_locked_price", async ({ page }) => {
  const id = await makeExam({ title: "Seats", seats: 5 });
  const a = await createAccount({ status: "active", firstName: "Ann" });
  const b = await createAccount({ status: "active", firstName: "Ben" });
  await insertBooking(id, a.id, "awaiting_payment");
  await insertBooking(id, b.id, "paid");
  await signInAdmin(page);
  await page.goto("/admin/exams");
  const r = row(page, "Seats");
  await expect(r).toContainText("2 / 5");
  await expect(r).toContainText("£15.00"); // price column
  await expect(r).toContainText("£15.00"); // money taken: one paid booking

  await r.getByRole("button", { name: "Edit" }).click();
  const edit = page.getByRole("form", { name: "Edit exam" });
  await edit.getByLabel("Seat limit").fill("1");
  await edit.getByRole("button", { name: "Save exam" }).click();
  await expect(edit.getByRole("alert")).toHaveText("The seat limit cannot be lower than the 2 seats already booked. Cancel some bookings first, or choose 2 or more.");
  expect((await exam("Seats"))?.seat_limit).toBe(5);

  await edit.getByLabel("Seat limit").fill("5");
  await edit.getByLabel("Price (£)").fill("20");
  await edit.getByRole("button", { name: "Save exam" }).click();
  await expect(edit.getByRole("alert")).toContainText("The price cannot be changed (it is currently £15.00) because this exam already has bookings.");
  expect((await exam("Seats"))?.price_pence).toBe(1500);

  await edit.getByLabel("Price (£)").fill("15");
  await edit.getByLabel("Seat limit").fill("2");
  await edit.getByRole("button", { name: "Save exam" }).click();
  await expect(page.getByRole("status")).toContainText("Exam saved");
  await expect(r).toContainText("2 / 2");
  expect((await exam("Seats"))?.seat_limit).toBe(2);
});

test("cancelling_an_exam_flags_paid_bookings_for_refund", async ({ page }) => {
  const id = await makeExam({ title: "Cancel me" });
  const unpaid = await createAccount({ status: "active", firstName: "Una" });
  const paid = await createAccount({ status: "active", firstName: "Pia" });
  const free = await createAccount({ status: "active", firstName: "Fay" });
  await insertBooking(id, unpaid.id, "awaiting_payment");
  await insertBooking(id, paid.id, "paid");
  await insertBooking(id, free.id, "paid", 0);
  await signInAdmin(page);
  await page.goto("/admin/exams");
  const r = row(page, "Cancel me");
  await expect(r).toContainText("3 / 10");

  await r.getByRole("button", { name: "Cancel exam" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toContainText("Paid bookings are flagged for a refund");
  await dialog.getByRole("button", { name: "Cancel", exact: true }).click();
  expect((await exam("Cancel me"))?.status).toBe("published");

  await r.getByRole("button", { name: "Cancel exam" }).click();
  await page.getByRole("dialog").getByRole("button", { name: "Cancel exam" }).click();
  await expect(page.getByRole("status")).toContainText("1 booking is flagged for a refund");
  await expect(r).toContainText("Cancelled");
  const refunds = page.getByTestId("exam-refunds").filter({ hasText: "Pia Tester" });
  await expect(refunds).toContainText("Refunds due: 1 booking, £15.00 in total");
  await expect(refunds).toContainText("Pia Tester: £15.00");
  await expect(refunds).not.toContainText("Una Tester");
  await expect(refunds).not.toContainText("Fay Tester");

  expect((await exam("Cancel me"))?.status).toBe("cancelled");
  expect(await bookingOf(id, unpaid.id)).toMatchObject({ status: "cancelled", refund_due: false });
  expect(await bookingOf(id, paid.id)).toMatchObject({ status: "cancel_requested", refund_due: true });
  expect(await bookingOf(id, free.id)).toMatchObject({ status: "cancelled", refund_due: false });
  // A cancelled exam has no actions left.
  await expect(r.getByRole("button")).toHaveCount(0);
});

test("teacher_sees_only_own_subjects_and_drafts_without_price_or_publish", async ({ page, browser }) => {
  const teacher = await createAccount({ role: "teacher", firstName: "Tess" });
  const { error } = await svc().from("teacher_subjects").insert({ teacher_id: teacher.id, subject_id: subjectId });
  if (error) throw new Error(`teacher link failed: ${error.message}`);
  await makeExam({ title: "Mine draft", status: "draft", by: teacher.id, price: 0, confirmed: false });
  await makeExam({ title: "Mine published" });
  await makeExam({ title: "Other draft", status: "draft", subject: subjectBId });
  await makeExam({ title: "Other published", subject: subjectBId });

  await signInUI(page, teacher.email, teacher.password);
  await expect(page).toHaveURL(/\/teacher$/);
  await expect(page.locator("aside").getByRole("link", { name: "Exams", exact: true })).toBeVisible();
  await page.locator("aside").getByRole("link", { name: "Exams", exact: true }).click();
  await expect(page).toHaveURL(/\/teacher\/exams$/);
  await expect(page.getByText("Preview — sample data")).toHaveCount(0);

  await expect(page.getByTestId("exam-row").filter({ hasText: `${tag} Mine draft` })).toHaveCount(1);
  await expect(page.getByTestId("exam-row").filter({ hasText: `${tag} Mine published` })).toHaveCount(1);
  await expect(page.getByText(`${tag} Other`)).toHaveCount(0);
  // No money and no publish or cancel controls anywhere.
  await expect(page.locator("body")).not.toContainText(SECRET_PRICE);
  await expect(page.getByRole("button", { name: /publish|cancel exam/i })).toHaveCount(0);
  await expect(page.getByRole("columnheader", { name: /price|money/i })).toHaveCount(0);
  // Published exams cannot be edited; the draft can.
  await expect(page.getByTestId("exam-row").filter({ hasText: `${tag} Mine published` }).getByRole("button")).toHaveCount(0);

  await page.getByRole("button", { name: "New draft exam" }).click();
  const form = page.getByRole("form", { name: "New exam" });
  await expect(form.getByLabel("Price (£)")).toHaveCount(0);
  await expect(form.getByLabel("Subject", { exact: true }).locator("option")).toHaveText([SUBJECT]);
  await form.getByLabel("Title").fill(`${tag} Teacher draft`);
  await form.getByLabel("Venue", { exact: true }).selectOption({ label: VENUE });
  await form.getByLabel("Room", { exact: true }).selectOption("Hall A");
  await form.getByLabel("Exam date (UK time)").fill(ymd(SUMMER));
  await form.getByLabel("Start time (UK time)").fill("09:00");
  await form.getByLabel("Booking deadline date").fill(ymd(daysBefore(SUMMER, 5)));
  await form.getByRole("button", { name: "Create exam" }).click();
  await expect(page.getByRole("status")).toContainText("Draft created");
  const mine = await exam("Teacher draft");
  expect(mine).toMatchObject({ status: "draft", price_pence: 0, price_confirmed: false, created_by: teacher.id, subject_id: subjectId });
  expect(mine?.starts_at).toBe(`${ymd(SUMMER)}T08:00:00+00:00`);

  // Edit it.
  const created = page.getByTestId("exam-row").filter({ hasText: `${tag} Teacher draft` });
  await created.getByRole("button", { name: "Edit" }).click();
  const edit = page.getByRole("form", { name: "Edit exam" });
  await edit.getByLabel("Title").fill(`${tag} Teacher draft renamed`);
  await edit.getByRole("button", { name: "Save exam" }).click();
  await expect(page.getByRole("status")).toContainText("Draft saved");
  expect(await exam("Teacher draft renamed")).not.toBeNull();

  // A teacher cannot open the admin exam page.
  await page.goto("/admin/exams");
  await expect(page).not.toHaveURL(/\/admin\/exams/);

  // The admin sees the teacher's draft with an unconfirmed price, and confirms it before publishing.
  const ctx = await browser.newContext({ baseURL: BASE });
  const adminPage = await ctx.newPage();
  await signInAdmin(adminPage);
  await adminPage.goto("/admin/exams");
  const ar = row(adminPage, "Teacher draft renamed");
  await expect(ar).toContainText("Price not confirmed");
  await expect(ar.getByRole("button", { name: "Publish" })).toBeDisabled();
  await ar.getByRole("button", { name: "Edit" }).click();
  const aedit = adminPage.getByRole("form", { name: "Edit exam" });
  await aedit.getByLabel("Price (£)").fill("8");
  await aedit.getByRole("button", { name: "Save exam" }).click();
  await expect(adminPage.getByRole("status")).toContainText("Exam saved");
  await expect(ar).not.toContainText("Price not confirmed");
  await expect(ar.getByRole("button", { name: "Publish" })).toBeEnabled();
  expect(await exam("Teacher draft renamed")).toMatchObject({ price_pence: 800, price_confirmed: true });
  await ctx.close();
});

test("venues_page_adds_edits_and_protects_venues_used_by_upcoming_exams", async ({ page }) => {
  await signInAdmin(page);
  await page.goto("/admin/venues");
  await expect(page.getByText("Preview — sample data")).toHaveCount(0);
  await expect(page.locator("aside").getByRole("link", { name: "Venues" })).toBeVisible();

  const name = `${VENUE} New`;
  await page.getByRole("button", { name: "New venue" }).click();
  const form = page.getByRole("form", { name: "New venue" });
  await form.getByLabel("Venue name").fill(name);
  await form.getByLabel("Rooms (one per line)").fill("Main hall\nLab 1\nLab 2");
  await form.getByRole("button", { name: "Add venue" }).click();
  await expect(page.getByRole("status")).toContainText("Venue added");
  const r = page.getByTestId("venue-row").filter({ hasText: name });
  await expect(r).toContainText("Main hall, Lab 1, Lab 2");
  await expect(r).toContainText("Active");

  // A repeated name is refused.
  await page.getByRole("button", { name: "New venue" }).click();
  const dup = page.getByRole("form", { name: "New venue" });
  await dup.getByLabel("Venue name").fill(name);
  await dup.getByRole("button", { name: "Add venue" }).click();
  await expect(dup.getByRole("alert")).toContainText("already exists");
  await dup.getByRole("button", { name: "Close" }).click();

  // Edit rooms and deactivate.
  await r.getByRole("button", { name: "Edit" }).click();
  const edit = page.getByRole("form", { name: "Edit venue" });
  await edit.getByLabel("Rooms (one per line)").fill("Main hall");
  await edit.getByLabel(/Active/).uncheck();
  await edit.getByRole("button", { name: "Save venue" }).click();
  await expect(page.getByRole("status")).toContainText("Venue saved");
  await expect(r).toContainText("Inactive");
  await expect(r).not.toContainText("Lab 1");

  // A venue with an upcoming exam cannot be deactivated or lose that exam's room.
  await makeExam({ title: "Uses venue" });
  const used = page.getByTestId("venue-row").filter({ hasText: VENUE }).filter({ hasNotText: "New" });
  await used.getByRole("button", { name: "Edit" }).click();
  const uedit = page.getByRole("form", { name: "Edit venue" });
  await uedit.getByLabel("Rooms (one per line)").fill("Hall B");
  await uedit.getByRole("button", { name: "Save venue" }).click();
  await expect(uedit.getByRole("alert")).toContainText("an upcoming exam still uses this venue or a room you removed");
  const { data } = await svc().from("venues").select("rooms").eq("id", venueId).single();
  expect(data?.rooms).toEqual(["Hall A", "Hall B"]);
});

test("owner_reaches_the_exam_pages_from_the_nav", async ({ page }) => {
  const owner = await createAccount({ role: "owner" });
  await signInUI(page, owner.email, owner.password);
  await expect(page).toHaveURL(/\/owner$/);
  await page.locator("aside").getByRole("link", { name: "Exams", exact: true }).click();
  await expect(page).toHaveURL(/\/admin\/exams$/);
  await expect(page.getByRole("button", { name: "New exam" })).toBeVisible();
  await page.goto("/admin/venues");
  await expect(page.getByRole("button", { name: "New venue" })).toBeVisible();
});
