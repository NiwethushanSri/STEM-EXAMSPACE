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

// Public timetable and family bookings. Serial. Every row it creates (subject, venue, exams, bookings, users) is removed again.

const tag = crypto.randomUUID().slice(0, 8);
const SUBJECT = `E2E Subject ${tag}`;
const VENUE = `E2E Venue ${tag}`;
const SECRET = `SECRET-${tag}`;

let subjectId: number;
let venueId: string;
let adminId: string;
const examIds: string[] = [];

type ExamOpts = {
  starts: string;
  deadline?: string;
  seats?: number;
  price?: number;
  status?: "draft" | "published";
  online?: boolean;
};

async function makeExam(o: ExamOpts): Promise<string> {
  const { data, error } = await svc()
    .from("exams")
    .insert({
      subject_id: subjectId,
      title: `${SECRET} title`,
      paper: `${SECRET} paper`,
      format: o.online ? "online" : "in_person",
      venue_id: o.online ? null : venueId,
      room: o.online ? null : `${SECRET} room`,
      starts_at: o.starts,
      duration_minutes: 90,
      seat_limit: o.seats ?? 10,
      price_pence: o.price ?? 1500,
      price_confirmed: true,
      booking_deadline: o.deadline ?? new Date(Date.parse(o.starts) - 3 * 86400_000).toISOString(),
      status: o.status ?? "published",
      created_by: adminId,
    })
    .select("id")
    .single();
  if (error || !data) throw new Error(`exam insert failed: ${error?.message}`);
  examIds.push(data.id);
  return data.id;
}

async function insertBooking(examId: string, studentId: string, status: "awaiting_payment" | "paid", amount = 1500) {
  const { error } = await svc().from("bookings").insert({ exam_id: examId, student_id: studentId, booked_by: studentId, status, amount_pence: amount });
  if (error) throw new Error(`booking insert failed: ${error.message}`);
}

async function bookingStatus(examId: string, studentId: string): Promise<string | undefined> {
  const { data } = await svc().from("bookings").select("status").eq("exam_id", examId).eq("student_id", studentId).maybeSingle();
  return data?.status;
}

async function student(first: string): Promise<TestAccount> {
  return createAccount({ status: "active", firstName: first });
}

async function link(parentId: string, studentId: string) {
  const { error } = await svc().from("parent_children").insert({ parent_id: parentId, student_id: studentId });
  if (error) throw new Error(`link failed: ${error.message}`);
}

async function removeData() {
  if (examIds.length) {
    await svc().from("bookings").delete().in("exam_id", examIds);
    await svc().from("exams").delete().in("id", examIds);
    examIds.length = 0;
  }
}

test.beforeAll(async () => {
  await assertNoOwner();
  const admin = await createAccount({ role: "admin" });
  adminId = admin.id;
  const s = await svc().from("subjects").insert({ name: SUBJECT, kind: "school" }).select("id").single();
  if (s.error || !s.data) throw new Error(`subject insert failed: ${s.error?.message}`);
  subjectId = s.data.id;
  const v = await svc().from("venues").insert({ name: VENUE }).select("id").single();
  if (v.error || !v.data) throw new Error(`venue insert failed: ${v.error?.message}`);
  venueId = v.data.id;
  for (const path of ["/exams", "/login", "/account/bookings"]) await fetch(`${BASE}${path}`, { redirect: "manual" }).catch(() => undefined);
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterEach(async () => {
  await removeData();
});
test.afterAll(async () => {
  await removeData();
  await svc().from("venues").delete().eq("id", venueId);
  await svc().from("subjects").delete().eq("id", subjectId);
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

const filtered = (p: Page) => p.goto(`/exams?subject=${encodeURIComponent(SUBJECT)}`);

test("public_timetable_shows_published_exams_in_london_time_and_hides_drafts", async ({ page }) => {
  await makeExam({ starts: "2027-06-12T08:00:00Z" }); // BST: 09:00
  await makeExam({ starts: "2027-12-11T09:00:00Z", online: true, price: 0 }); // GMT: 09:00
  await makeExam({ starts: "2027-06-19T08:00:00Z", status: "draft" });
  await filtered(page);
  const rows = page.getByTestId("exam-row");
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0)).toContainText("Sat 12 Jun 2027, 09:00");
  await expect(rows.nth(0)).toContainText("90 min");
  await expect(rows.nth(0)).toContainText(VENUE);
  await expect(rows.nth(0)).toContainText("£15.00");
  await expect(rows.nth(0)).toContainText("10 seats left");
  await expect(rows.nth(0)).toContainText("Book by Wed 9 Jun 2027, 09:00");
  await expect(rows.nth(1)).toContainText("Sat 11 Dec 2027, 09:00");
  await expect(rows.nth(1)).toContainText("Online");
  await expect(rows.nth(1)).toContainText("Free");
  // Nothing beyond the public fields is rendered.
  await expect(page.locator("body")).not.toContainText(SECRET);
  await expect(page.getByRole("navigation", { name: "Subject filter" }).getByRole("link", { name: SUBJECT })).toBeVisible();
});

test("public_timetable_disables_closed_and_full_exams_and_book_goes_to_login", async ({ page }) => {
  const open = await makeExam({ starts: "2027-06-12T08:00:00Z" });
  await makeExam({ starts: "2027-06-13T08:00:00Z", deadline: "2026-01-01T00:00:00Z" });
  const fullExam = await makeExam({ starts: "2027-06-14T08:00:00Z", seats: 1 });
  const other = await student("Other");
  await insertBooking(fullExam, other.id, "paid");
  await filtered(page);
  const rows = page.getByTestId("exam-row");
  await expect(rows).toHaveCount(3);
  await expect(rows.nth(1).getByRole("button", { name: "Booking closed" })).toBeDisabled();
  await expect(rows.nth(1).getByRole("link", { name: "Book" })).toHaveCount(0);
  await expect(rows.nth(2).getByRole("button", { name: "Fully booked" })).toBeDisabled();
  await expect(rows.nth(2)).toContainText("No seats left");
  await rows.nth(0).getByRole("link", { name: "Book" }).click();
  await expect(page).toHaveURL(new RegExp(`/login\\?next=${encodeURIComponent(`/exams/${open}/book`)}`));
});

test("parent_books_for_child_and_cancels_unpaid_booking", async ({ page }) => {
  const exam = await makeExam({ starts: "2027-06-12T08:00:00Z" });
  const parent = await createAccount({ role: "parent", firstName: "Pat" });
  const kid = await student("Kiddo");
  const kid2 = await student("Zed");
  await link(parent.id, kid.id);
  await link(parent.id, kid2.id);
  await signInUI(page, parent.email, parent.password);
  await expect(page).toHaveURL(/\/account\/home$/);
  await expect(page.getByRole("link", { name: "My bookings" })).toBeVisible();
  await filtered(page);
  await page.getByTestId("exam-row").getByRole("link", { name: "Book" }).click();
  await expect(page).toHaveURL(new RegExp(`/exams/${exam}/book$`));
  await expect(page.getByText("You will pay the institution directly — your booking is held until the booking deadline")).toBeVisible();
  await expect(page.getByText("£15.00").first()).toBeVisible();
  await page.getByLabel("Book for").selectOption({ label: "Kiddo Tester" });
  await page.getByRole("button", { name: "Confirm booking" }).click();
  await expect(page).toHaveURL(/\/account\/bookings\?booked=1$/);
  const row = page.getByTestId("booking-row");
  await expect(row).toHaveCount(1);
  await expect(row).toContainText("Awaiting payment");
  await expect(row).toContainText("For Kiddo Tester");
  await expect(row).toContainText("Sat 12 Jun 2027, 09:00");
  expect(await bookingStatus(exam, kid.id)).toBe("awaiting_payment");
  expect(await bookingStatus(exam, kid2.id)).toBeUndefined();

  // A second booking for the same child is refused with a message.
  await page.goto(`/exams/${exam}/book`);
  await page.getByLabel("Book for").selectOption({ label: "Kiddo Tester" });
  await page.getByRole("button", { name: "Confirm booking" }).click();
  await expect(page.locator("main [role=alert]")).toHaveText("This student already has a booking for this exam.");

  // Unpaid bookings are cancelled behind a confirm step.
  await page.goto("/account/bookings");
  await page.getByRole("button", { name: "Cancel booking" }).click();
  await page.getByRole("button", { name: "Keep booking" }).click();
  await expect(page.getByRole("button", { name: "Cancel booking" })).toBeVisible();
  await page.getByRole("button", { name: "Cancel booking" }).click();
  await page.getByRole("button", { name: "Yes, confirm" }).click();
  await expect(page.getByTestId("booking-row")).toContainText("Cancelled");
  await expect.poll(() => bookingStatus(exam, kid.id)).toBe("cancelled");
  await page.reload();
  await expect(page.getByTestId("booking-row")).toContainText("Cancelled");
  await expect(page.getByRole("button", { name: "Cancel booking" })).toHaveCount(0);
});

test("student_books_self_and_returns_after_login", async ({ page }) => {
  const exam = await makeExam({ starts: "2027-12-11T09:00:00Z" });
  const me = await student("Selma");
  // Signed out: the Book page sends to login with a return path, and sign-in comes back to it.
  await page.goto(`/exams/${exam}/book`);
  await expect(page).toHaveURL(/\/login\?next=/);
  await page.waitForLoadState("networkidle"); // the form must be hydrated before it is used
  await page.getByLabel("Email or index number").fill(me.email);
  await page.getByLabel("Password", { exact: true }).fill(me.password);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page).toHaveURL(new RegExp(`/exams/${exam}/book$`));
  await expect(page.getByLabel("Book for")).toHaveCount(0);
  await page.getByRole("button", { name: "Confirm booking" }).click();
  await expect(page).toHaveURL(/\/account\/bookings\?booked=1$/);
  const row = page.getByTestId("booking-row");
  await expect(row).toContainText("Awaiting payment");
  await expect(row).toContainText("Sat 11 Dec 2027, 09:00");
  await expect(row).not.toContainText("For ");
  expect(await bookingStatus(exam, me.id)).toBe("awaiting_payment");
});

test("external_return_path_is_ignored_at_login", async ({ page }) => {
  const me = await student("Ivy");
  await page.goto(`/login?next=${encodeURIComponent("https://evil.example/steal")}`);
  await page.waitForLoadState("networkidle");
  await page.getByLabel("Email or index number").fill(me.email);
  await page.getByLabel("Password", { exact: true }).fill(me.password);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page).toHaveURL(/\/account\/home$/);
});

test("fully_booked_exam_shows_message", async ({ page }) => {
  const exam = await makeExam({ starts: "2027-06-12T08:00:00Z", seats: 1 });
  const me = await student("Late");
  const other = await student("Early");
  await signInUI(page, me.email, me.password);
  await expect(page).toHaveURL(/\/account\/home$/);
  // The last seat goes while the page is open: the action reports it.
  await page.goto(`/exams/${exam}/book`);
  await expect(page.getByRole("button", { name: "Confirm booking" })).toBeVisible();
  await insertBooking(exam, other.id, "paid");
  await page.getByRole("button", { name: "Confirm booking" }).click();
  await expect(page.locator("main [role=alert]")).toHaveText("This exam is fully booked");
  // A fresh visit shows the same message instead of the form.
  await page.goto(`/exams/${exam}/book`);
  await expect(page.locator("main [role=alert]")).toHaveText("This exam is fully booked");
  await expect(page.getByRole("button", { name: "Confirm booking" })).toHaveCount(0);
  expect(await bookingStatus(exam, me.id)).toBeUndefined();
});

test("paid_booking_can_request_cancellation", async ({ page }) => {
  const exam = await makeExam({ starts: "2027-06-12T08:00:00Z" });
  const parent = await createAccount({ role: "parent", firstName: "Pam" });
  const kid = await student("Paidkid");
  await link(parent.id, kid.id);
  await insertBooking(exam, kid.id, "paid");
  await signInUI(page, parent.email, parent.password);
  await expect(page).toHaveURL(/\/account\/home$/);
  await page.goto("/account/bookings");
  const row = page.getByTestId("booking-row");
  await expect(row).toContainText("Paid");
  await expect(page.getByRole("button", { name: "Cancel booking" })).toHaveCount(0);
  await page.getByRole("button", { name: "Request cancellation" }).click();
  await page.getByRole("button", { name: "Yes, confirm" }).click();
  await expect(page.getByTestId("booking-row")).toContainText("Cancellation requested");
  await expect.poll(() => bookingStatus(exam, kid.id)).toBe("cancel_requested");
  await page.reload();
  await expect(page.getByTestId("booking-row")).toContainText("Cancellation requested");
  await expect(page.getByRole("button", { name: "Request cancellation" })).toHaveCount(0);
});

test("bookings_are_private_to_the_family", async ({ page }) => {
  const exam = await makeExam({ starts: "2027-06-12T08:00:00Z" });
  const stranger = await createAccount({ role: "parent", firstName: "Stranger" });
  const kid = await student("Hidden");
  await insertBooking(exam, kid.id, "paid");
  await signInUI(page, stranger.email, stranger.password);
  await expect(page).toHaveURL(/\/account\/home$/);
  await page.goto("/account/bookings");
  await expect(page.getByTestId("booking-row")).toHaveCount(0);
  await expect(page.getByText("No upcoming bookings.")).toBeVisible();
});
