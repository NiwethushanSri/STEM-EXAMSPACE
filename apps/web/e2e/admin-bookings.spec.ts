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

// Admin bookings and finance pages. Serial. Every row it creates (subject, exams, bookings, users) is removed again.

const tag = crypto.randomUUID().slice(0, 8);
const SUBJECT = `E2E Subject ${tag}`;
const inDays = (n: number) => new Date(Date.now() + n * 86400_000).toISOString();

// Money tests use a year well away from real data, taken from the clock.
const Y5 = new Date().getUTCFullYear() + 5;

let adminId: string;
let admin: TestAccount;
let subjectId: number;
let indexCounter = 9000 + Math.floor(Math.random() * 800);
const examIds: string[] = [];

async function makeExam(o: {
  title: string;
  price?: number;
  starts?: string;
  deadline?: string;
  status?: "draft" | "published" | "cancelled";
  confirmed?: boolean;
}): Promise<string> {
  const starts = o.starts ?? inDays(30);
  const { data, error } = await svc()
    .from("exams")
    .insert({
      subject_id: subjectId,
      title: `${tag} ${o.title}`,
      paper: "Paper 1",
      format: "online",
      starts_at: starts,
      duration_minutes: 60,
      seat_limit: 50,
      price_pence: o.price ?? 2000,
      price_confirmed: o.confirmed ?? true,
      booking_deadline: o.deadline ?? new Date(Date.parse(starts) - 3 * 86400_000).toISOString(),
      status: o.status ?? "published",
      created_by: adminId,
    })
    .select("id")
    .single();
  if (error || !data) throw new Error(`exam insert failed: ${error?.message}`);
  examIds.push(data.id);
  return data.id;
}

type Seed = {
  status: "awaiting_payment" | "paid" | "cancel_requested" | "part_refunded" | "refunded" | "cancelled";
  amount?: number;
  refunded?: number;
  due?: boolean;
  paidAt?: string | null;
};

async function insertBooking(examId: string, studentId: string, s: Seed): Promise<string> {
  const row: Record<string, unknown> = {
    exam_id: examId,
    student_id: studentId,
    booked_by: studentId,
    status: s.status,
    amount_pence: s.amount ?? 2000,
    refunded_pence: s.refunded ?? 0,
    refund_due: s.due ?? false,
  };
  if (s.paidAt !== undefined) row.paid_at = s.paidAt;
  const { data, error } = await svc().from("bookings").insert(row).select("id").single();
  if (error || !data) throw new Error(`booking insert failed: ${error?.message}`);
  return data.id;
}

async function bookingById(id: string) {
  const { data } = await svc().from("bookings").select("status, amount_pence, refunded_pence, refund_due, paid_offline, paid_at, notes").eq("id", id).single();
  return data;
}

async function bookingOf(examId: string, studentId: string) {
  const { data } = await svc()
    .from("bookings")
    .select("id, status, paid_offline, paid_at, notes, amount_pence")
    .eq("exam_id", examId)
    .eq("student_id", studentId)
    .maybeSingle();
  return data;
}

/** An active student whose first name carries the run tag, with an index number. */
async function student(first: string): Promise<TestAccount & { name: string }> {
  const a = await createAccount({ status: "active", firstName: `${first}${tag}`, indexNumber: `SE-2026-${indexCounter++}` });
  return { ...a, name: `${first}${tag} Tester` };
}

async function removeData() {
  if (examIds.length) {
    await svc().from("bookings").delete().in("exam_id", examIds);
    await svc().from("exams").delete().in("id", examIds);
    examIds.length = 0;
  }
}

async function signInAdmin(page: Page) {
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
}

const bookingRows = (p: Page) => p.getByTestId("booking-row");
const decisionRow = (p: Page, name: string) => p.getByTestId("decision-row").filter({ hasText: name });
const dialog = (p: Page) => p.getByRole("dialog");

test.beforeAll(async () => {
  await assertNoOwner();
  admin = await createAccount({ role: "admin" });
  adminId = admin.id;
  const s = await svc().from("subjects").insert({ name: SUBJECT, kind: "school" }).select("id").single();
  if (s.error || !s.data) throw new Error(`subject insert failed: ${s.error?.message}`);
  subjectId = s.data.id;
  for (const path of ["/login", "/admin", "/admin/bookings", "/admin/finance", "/teacher", "/tutor", "/corrector"]) {
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
  await svc().from("subjects").delete().eq("id", subjectId);
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

test("filters_by_status_exam_and_search_safely_and_caps_the_list_at_500", async ({ page }) => {
  const e1 = await makeExam({ title: "One" });
  const e2 = await makeExam({ title: "Two" });
  const a = await student("Alpha");
  const b = await student("Bravo");
  await insertBooking(e1, a.id, { status: "paid", paidAt: inDays(-1) });
  await insertBooking(e1, b.id, { status: "awaiting_payment" });
  await insertBooking(e2, a.id, { status: "cancelled" });
  await insertBooking(e2, b.id, { status: "paid", paidAt: inDays(-1) });

  await signInAdmin(page);
  await page.goto("/admin/bookings");
  await expect(page.getByRole("heading", { name: "Bookings & payments", exact: true })).toBeVisible();
  await expect(page.getByText("Preview — sample data")).toHaveCount(0);

  // Exam filter, through the form.
  const filter = page.getByRole("form", { name: "Filter bookings" });
  await filter.getByLabel("Exam").selectOption(e1);
  await filter.getByRole("button", { name: "Apply filters" }).click();
  await expect(page).toHaveURL(new RegExp(`exam=${e1}`));
  await expect(bookingRows(page)).toHaveCount(2);

  // Status filter within that exam.
  await filter.getByLabel("Status").selectOption("awaiting_payment");
  await filter.getByRole("button", { name: "Apply filters" }).click();
  await expect(bookingRows(page)).toHaveCount(1);
  await expect(bookingRows(page).first()).toContainText(b.name);
  await expect(bookingRows(page).first()).toContainText("Awaiting payment");

  // Search by name word, by index number, by both words of a full name.
  await page.goto(`/admin/bookings?exam=${e1}&q=${encodeURIComponent(`Alpha${tag}`)}`);
  await expect(bookingRows(page)).toHaveCount(1);
  await expect(bookingRows(page).first()).toContainText(a.name);
  await page.goto(`/admin/bookings?exam=${e1}&q=${encodeURIComponent(b.indexNumber!)}`);
  await expect(bookingRows(page)).toHaveCount(1);
  await expect(bookingRows(page).first()).toContainText(b.name);
  await expect(bookingRows(page).first()).toContainText(b.indexNumber!);
  await page.goto(`/admin/bookings?exam=${e2}&q=${encodeURIComponent(`Bravo${tag} Tester`)}`);
  await expect(bookingRows(page)).toHaveCount(1);
  await expect(bookingRows(page).first()).toContainText("Paid");

  // Commas, brackets, quotes and LIKE wildcards are plain text: no error, and nothing matches.
  for (const q of [`Alpha${tag},first_name.eq.x)(`, `Alph_${tag}`, "%", `"),or(id.neq.0`, "\\"]) {
    await page.goto(`/admin/bookings?exam=${e1}&q=${encodeURIComponent(q)}`);
    await expect(page.getByText("No bookings match these filters.")).toBeVisible();
    await expect(bookingRows(page)).toHaveCount(0);
  }
  // A bad status or exam value is ignored rather than breaking the page.
  await page.goto(`/admin/bookings?status=nope&exam=not-a-uuid&q=Alpha${tag}`);
  await expect(bookingRows(page)).toHaveCount(2);

  // Clear filters.
  await page.goto(`/admin/bookings?exam=${e1}&status=paid`);
  await page.getByRole("link", { name: "Clear filters" }).click();
  await expect(page).toHaveURL(/\/admin\/bookings$/);
});

test("list_is_capped_at_500_with_a_note", async ({ page }) => {
  const exam = await makeExam({ title: "Capped" });
  const a = await student("Cap");
  const rows = Array.from({ length: 501 }, () => ({
    exam_id: exam,
    student_id: a.id,
    booked_by: a.id,
    status: "cancelled" as const,
    amount_pence: 2000,
  }));
  const { error } = await svc().from("bookings").insert(rows);
  if (error) throw new Error(`bulk insert failed: ${error.message}`);
  await signInAdmin(page);
  await page.goto(`/admin/bookings?exam=${exam}`);
  await expect(bookingRows(page)).toHaveCount(500);
  await expect(page.getByText("Showing the newest 500 bookings that match.")).toBeVisible();
});

test("adds_offline_bookings_unpaid_and_paid_and_explains_refusals", async ({ page }) => {
  const open = await makeExam({ title: "Open", price: 1500 });
  const late = await makeExam({ title: "Late deadline", price: 1500, starts: inDays(10), deadline: inDays(-1) });
  await makeExam({ title: "Draft", status: "draft" });
  const s1 = await student("Cora");
  const s2 = await student("Dane");
  await signInAdmin(page);
  await page.goto("/admin/bookings");

  const form = page.getByRole("form", { name: "Add offline booking" });
  // Only bookable exams are offered.
  await expect(form.getByLabel("Exam", { exact: true }).locator(`option[value="${open}"]`)).toHaveCount(1);
  await expect(form.getByLabel("Exam", { exact: true }).locator("option", { hasText: `${tag} Draft` })).toHaveCount(0);
  await expect(form.getByText("Visible to the family, their tutor and the subject's teachers. Don't include personal details.")).toBeVisible();

  async function fill(examId: string, who: TestAccount & { name: string }, byIndex: boolean, payment: "paid" | "unpaid", note = "") {
    await form.getByLabel("Exam", { exact: true }).selectOption(examId);
    await form.getByLabel("Find student (name or index number)").fill(byIndex ? who.indexNumber! : who.name.split(" ")[0]);
    await form.getByRole("button", { name: "Find student" }).click();
    await form.getByLabel("Student", { exact: true }).selectOption({ label: `${who.name} — ${who.indexNumber}` });
    await form.getByLabel("Payment").selectOption(payment);
    await form.getByLabel("Note (optional)").fill(note);
    await form.getByRole("button", { name: "Add booking" }).click();
  }

  // Unpaid, found by index number; the confirm step can be backed out of.
  await fill(open, s1, true, "unpaid", "phone call");
  await expect(dialog(page)).toContainText(`${s1.name} will be booked`);
  await dialog(page).getByRole("button", { name: "Cancel", exact: true }).click();
  expect(await bookingOf(open, s1.id)).toBeNull();
  await form.getByRole("button", { name: "Add booking" }).click();
  await dialog(page).getByRole("button", { name: "Add booking" }).click();
  await expect(page.getByRole("status")).toContainText("Booking added. It is awaiting payment.");
  const b1 = await bookingOf(open, s1.id);
  expect(b1?.status).toBe("awaiting_payment");
  expect(b1?.notes).toBe("phone call");
  expect(b1?.paid_at).toBeNull();
  await page.goto(`/admin/bookings?exam=${open}`);
  await expect(bookingRows(page)).toHaveCount(1);
  await expect(bookingRows(page).first()).toContainText(s1.name);
  await expect(bookingRows(page).first()).toContainText("Awaiting payment");
  await expect(bookingRows(page).first()).toContainText("£15.00");

  // Paid, found by name; paid_at is stamped now.
  await fill(open, s2, false, "paid");
  await dialog(page).getByRole("button", { name: "Add booking" }).click();
  await expect(page.getByRole("status")).toContainText("Booking added and marked as paid.");
  const b2 = await bookingOf(open, s2.id);
  expect(b2?.status).toBe("paid");
  expect(b2?.paid_offline).toBe(true);
  expect(Math.abs(Date.now() - Date.parse(b2!.paid_at!))).toBeLessThan(120_000);

  // The same student twice is refused with a message.
  await fill(open, s2, false, "unpaid");
  await dialog(page).getByRole("button", { name: "Add booking" }).click();
  await expect(page.locator("main [role=alert]").filter({ hasText: "already has a booking" })).toBeVisible();

  // After the deadline an unpaid booking is refused, a paid one is accepted.
  await fill(late, s1, true, "unpaid");
  await dialog(page).getByRole("button", { name: "Add booking" }).click();
  await expect(page.locator("main [role=alert]").filter({ hasText: "The booking deadline has passed" })).toBeVisible();
  expect(await bookingOf(late, s1.id)).toBeNull();
  await fill(late, s1, true, "paid");
  await dialog(page).getByRole("button", { name: "Add booking" }).click();
  await expect(page.getByRole("status")).toContainText("Booking added and marked as paid.");
  expect((await bookingOf(late, s1.id))?.status).toBe("paid");

  // A search with no match says so.
  await form.getByLabel("Find student (name or index number)").fill("zzzznomatch");
  await form.getByRole("button", { name: "Find student" }).click();
  await expect(form.getByLabel("Student", { exact: true }).locator("option", { hasText: "No active student found" })).toHaveCount(1);
});

test("marks_an_unpaid_booking_paid_and_cancels_another_behind_confirm_steps", async ({ page }) => {
  const exam = await makeExam({ title: "Pay" });
  const s1 = await student("Eve");
  const s2 = await student("Finn");
  const s3 = await student("Gus");
  await insertBooking(exam, s1.id, { status: "awaiting_payment" });
  await insertBooking(exam, s2.id, { status: "awaiting_payment" });
  await insertBooking(exam, s3.id, { status: "paid", paidAt: inDays(-2) });
  await signInAdmin(page);
  await page.goto(`/admin/bookings?exam=${exam}`);
  await expect(bookingRows(page)).toHaveCount(3);
  const row1 = bookingRows(page).filter({ hasText: s1.name });
  const row2 = bookingRows(page).filter({ hasText: s2.name });
  const row3 = bookingRows(page).filter({ hasText: s3.name });
  // Only unpaid rows have the buttons.
  await expect(row3.getByRole("button")).toHaveCount(0);

  await row1.getByRole("button", { name: "Mark paid" }).click();
  await expect(dialog(page).getByText("Visible to the family, their tutor and the subject's teachers. Don't include personal details.")).toBeVisible();
  await dialog(page).getByRole("button", { name: "Cancel", exact: true }).click();
  expect((await bookingOf(exam, s1.id))?.status).toBe("awaiting_payment");
  await row1.getByRole("button", { name: "Mark paid" }).click();
  await dialog(page).getByLabel("Note (optional)").fill("cash at the desk");
  await dialog(page).getByRole("button", { name: "Mark paid" }).click();
  await expect(page.getByRole("status")).toContainText("Booking marked as paid.");
  await expect(row1).toContainText("Paid offline");
  const p1 = await bookingOf(exam, s1.id);
  expect(p1?.status).toBe("paid");
  expect(p1?.paid_offline).toBe(true);
  expect(p1?.notes).toBe("cash at the desk");
  expect(Math.abs(Date.now() - Date.parse(p1!.paid_at!))).toBeLessThan(120_000);
  await expect(row1.getByRole("button")).toHaveCount(0);

  await row2.getByRole("button", { name: "Cancel booking" }).click();
  await dialog(page).getByRole("button", { name: "Cancel", exact: true }).click();
  expect((await bookingOf(exam, s2.id))?.status).toBe("awaiting_payment");
  await row2.getByRole("button", { name: "Cancel booking" }).click();
  await dialog(page).getByRole("button", { name: "Cancel booking" }).click();
  await expect(page.getByRole("status")).toContainText("Booking cancelled.");
  await expect(row2).toContainText("Cancelled");
  expect((await bookingOf(exam, s2.id))?.status).toBe("cancelled");

  // The booking was paid by someone else meanwhile: the stale button reports it instead of failing silently.
  const s4 = await student("Hana");
  const id4 = await insertBooking(exam, s4.id, { status: "awaiting_payment" });
  await page.reload();
  await svc().from("bookings").update({ status: "paid" }).eq("id", id4);
  await bookingRows(page).filter({ hasText: s4.name }).getByRole("button", { name: "Mark paid" }).click();
  await dialog(page).getByRole("button", { name: "Mark paid" }).click();
  await expect(page.locator("main [role=alert]").filter({ hasText: "already changed" })).toBeVisible();
});

test("approves_partial_and_full_refunds_declines_and_warns_before_a_zero_refund_on_a_cancelled_exam", async ({ page }) => {
  const exam = await makeExam({ title: "Refunds", price: 2000 });
  const cancelled = await makeExam({ title: "Cancelled exam", price: 1500, status: "cancelled" });
  const s1 = await student("Ivo");
  const s2 = await student("Jade");
  const s3 = await student("Kit");
  const s4 = await student("Lena");
  const b1 = await insertBooking(exam, s1.id, { status: "cancel_requested", paidAt: inDays(-3) });
  const b2 = await insertBooking(exam, s2.id, { status: "cancel_requested", paidAt: inDays(-3) });
  const b3 = await insertBooking(exam, s3.id, { status: "cancel_requested", paidAt: inDays(-3) });
  const b4 = await insertBooking(cancelled, s4.id, { status: "cancelled", amount: 1500, due: true, paidAt: inDays(-3) });
  const b5 = await insertBooking(cancelled, s1.id, { status: "part_refunded", amount: 1500, refunded: 500, due: true, paidAt: inDays(-3) });
  await signInAdmin(page);
  await page.goto("/admin/bookings");
  await expect(page.getByRole("heading", { name: "Cancellation requests and refunds due" })).toBeVisible();

  // Partial refund: the amounts are shown, the field is prefilled with what is left.
  const r1 = decisionRow(page, s1.name).filter({ hasText: "Paid £20.00" });
  await expect(r1).toContainText("Already refunded £0.00");
  await expect(r1).toContainText("Still refundable £20.00");
  await expect(r1.getByLabel("Refund amount (£)")).toHaveValue("20.00");
  await expect(r1.getByText("Visible to the family, their tutor and the subject's teachers. Don't include personal details.")).toBeVisible();
  await expect(r1.getByRole("button", { name: "Decline" })).toBeVisible();
  await r1.getByLabel("Refund amount (£)").fill("30");
  await r1.getByRole("button", { name: "Approve" }).click();
  await expect(r1.getByRole("alert")).toContainText("cannot be more than £20.00");
  await r1.getByLabel("Refund amount (£)").fill("abc");
  await r1.getByRole("button", { name: "Approve" }).click();
  await expect(r1.getByRole("alert")).toContainText("Enter the refund in pounds");
  expect((await bookingById(b1))?.status).toBe("cancel_requested");

  await r1.getByLabel("Refund amount (£)").fill("7.50");
  await r1.getByLabel("Note (optional)").fill("refunded by bank transfer");
  await r1.getByRole("button", { name: "Approve" }).click();
  await expect(dialog(page)).toContainText("refund of £7.50 out of £20.00");
  await expect(dialog(page)).not.toContainText("This exam was cancelled");
  await dialog(page).getByRole("button", { name: "Cancel", exact: true }).click();
  expect((await bookingById(b1))?.status).toBe("cancel_requested");
  await r1.getByRole("button", { name: "Approve" }).click();
  await dialog(page).getByRole("button", { name: "Approve cancellation" }).click();
  await expect(page.getByRole("status")).toContainText("refund recorded");
  const after1 = await bookingById(b1);
  expect(after1?.status).toBe("part_refunded");
  expect(after1?.refunded_pence).toBe(750);
  expect(after1?.refund_due).toBe(false);
  expect(after1?.notes).toBe("refunded by bank transfer");
  await expect(page.getByTestId("decision-row").filter({ hasText: s1.name }).filter({ hasText: "Paid £20.00" })).toHaveCount(0);

  // Full refund with the prefilled amount.
  const r2 = decisionRow(page, s2.name);
  await expect(r2.getByLabel("Refund amount (£)")).toHaveValue("20.00");
  await r2.getByRole("button", { name: "Approve" }).click();
  await dialog(page).getByRole("button", { name: "Approve cancellation" }).click();
  await expect(page.getByRole("status")).toContainText("refund recorded");
  const after2 = await bookingById(b2);
  expect(after2?.status).toBe("refunded");
  expect(after2?.refunded_pence).toBe(2000);

  // Decline sends the booking back to paid.
  const r3 = decisionRow(page, s3.name);
  await r3.getByRole("button", { name: "Decline" }).click();
  await dialog(page).getByRole("button", { name: "Cancel", exact: true }).click();
  expect((await bookingById(b3))?.status).toBe("cancel_requested");
  await r3.getByRole("button", { name: "Decline" }).click();
  await dialog(page).getByRole("button", { name: "Decline cancellation" }).click();
  await expect(page.getByRole("status")).toContainText("Cancellation declined");
  expect((await bookingById(b3))?.status).toBe("paid");
  await expect(decisionRow(page, s3.name)).toHaveCount(0);

  // Refund-due rows (the exam was cancelled): no Decline, and a warning before approving £0.
  const r4 = decisionRow(page, s4.name);
  await expect(r4).toContainText("Refund due");
  await expect(r4).toContainText("Still refundable £15.00");
  await expect(r4.getByRole("button", { name: "Decline" })).toHaveCount(0);
  await r4.getByLabel("Refund amount (£)").fill("0");
  await r4.getByRole("button", { name: "Approve" }).click();
  await expect(dialog(page)).toContainText("This exam was cancelled — the family is owed a full refund.");
  await dialog(page).getByRole("button", { name: "Cancel", exact: true }).click();
  expect((await bookingById(b4))?.refund_due).toBe(true);
  // A non-zero amount shows no warning; approving clears the flag.
  await r4.getByLabel("Refund amount (£)").fill("15");
  await r4.getByRole("button", { name: "Approve" }).click();
  await expect(dialog(page)).not.toContainText("This exam was cancelled");
  await dialog(page).getByRole("button", { name: "Approve cancellation" }).click();
  await expect(page.getByRole("status")).toContainText("refund recorded");
  const after4 = await bookingById(b4);
  expect(after4?.status).toBe("refunded");
  expect(after4?.refunded_pence).toBe(1500);
  expect(after4?.refund_due).toBe(false);

  // A part-refunded refund-due row shows what is left (£10.00) and no Decline.
  const r5 = page.getByTestId("decision-row").filter({ hasText: s1.name }).filter({ hasText: "Paid £15.00" });
  await expect(r5).toContainText("Already refunded £5.00");
  await expect(r5).toContainText("Still refundable £10.00");
  await expect(r5.getByLabel("Refund amount (£)")).toHaveValue("10.00");
  await expect(r5.getByRole("button", { name: "Decline" })).toHaveCount(0);
  await r5.getByLabel("Refund amount (£)").fill("0");
  await r5.getByRole("button", { name: "Approve" }).click();
  await expect(dialog(page)).toContainText("the family is owed a full refund");
  await dialog(page).getByRole("button", { name: "Approve cancellation" }).click();
  await expect(page.getByRole("status")).toContainText("approved with no refund");
  const after5 = await bookingById(b5);
  expect(after5?.status).toBe("part_refunded");
  expect(after5?.refund_due).toBe(false);
});

test("finance_totals_match_the_seeded_bookings_exactly_across_a_bst_gmt_boundary", async ({ page }) => {
  const a = await makeExam({ title: "Fin A", price: 2000, starts: `${Y5}-12-06T09:00:00Z` });
  const b = await makeExam({ title: "Fin B", price: 1500, starts: `${Y5}-12-07T09:00:00Z` });
  const c = await makeExam({ title: "Fin C", price: 0, starts: `${Y5}-12-08T09:00:00Z` });
  const s1 = await student("Mo");
  const s2 = await student("Nia");
  const s3 = await student("Ola");
  // Exam A: paid; a part refund paid at 23:30 UTC on 31 Oct (31 Oct in London); a full refund paid at 00:30 on 1 Nov.
  await insertBooking(a, s1.id, { status: "paid", amount: 2000, paidAt: `${Y5}-10-10T12:00:00Z` });
  await insertBooking(a, s2.id, { status: "part_refunded", amount: 2000, refunded: 500, paidAt: `${Y5}-10-31T23:30:00Z` });
  await insertBooking(a, s3.id, { status: "refunded", amount: 2000, refunded: 2000, paidAt: `${Y5}-11-01T00:30:00Z` });
  // Exam B: unpaid (not counted); refund-due cancelled, paid at 23:30 UTC on 30 Sep (00:30 BST on 1 Oct); paid on 30 Sep at 23:30 BST (outside the range).
  await insertBooking(b, s1.id, { status: "awaiting_payment", amount: 1500 });
  await insertBooking(b, s2.id, { status: "cancelled", amount: 1500, due: true, paidAt: `${Y5}-09-30T23:30:00Z` });
  await insertBooking(b, s3.id, { status: "paid", amount: 1500, paidAt: `${Y5}-09-30T22:30:00Z` });
  // Exam C is free.
  await insertBooking(c, s1.id, { status: "paid", amount: 0, paidAt: `${Y5}-11-15T10:00:00Z` });

  await signInAdmin(page);
  await page.goto("/admin/finance");
  await expect(page.getByRole("heading", { name: "Finance", exact: true })).toBeVisible();
  await expect(page.getByText("Preview — sample data")).toHaveCount(0);
  await expect(page.getByText("Refunds are shown against the month the booking was paid.")).toBeVisible();

  // The default range is the current London financial year (1 Sep to 31 Aug).
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", year: "numeric", month: "2-digit" }).formatToParts(new Date()).map((p) => [p.type, p.value]),
  );
  const startYear = Number(parts.month) >= 9 ? Number(parts.year) : Number(parts.year) - 1;
  await expect(page.getByLabel("From", { exact: true })).toHaveValue(`${startYear}-09-01`);
  await expect(page.getByLabel("To", { exact: true })).toHaveValue(`${startYear + 1}-08-31`);

  // October and November Y5, through the form.
  await page.getByLabel("From", { exact: true }).fill(`${Y5}-10-01`);
  await page.getByLabel("To", { exact: true }).fill(`${Y5}-11-30`);
  await page.getByRole("button", { name: "Show totals" }).click();
  await expect(page).toHaveURL(new RegExp(`from=${Y5}-10-01&to=${Y5}-11-30`));
  const stats = page.getByTestId("finance-total");
  await expect(stats).toContainText("Money taken£75.00");
  await expect(stats).toContainText("Refunded£25.00");
  await expect(stats).toContainText("Net£50.00");

  const months = page.getByTestId("month-row");
  await expect(months).toHaveCount(2);
  await expect(months.nth(0).locator("td")).toHaveText([`October ${Y5}`, "3", "£55.00", "£5.00", "£50.00"]);
  await expect(months.nth(1).locator("td")).toHaveText([`November ${Y5}`, "2", "£20.00", "£20.00", "£0.00"]);

  const exams = page.getByTestId("exam-money-row");
  await expect(exams).toHaveCount(3);
  const rowOf = (t: string) => exams.filter({ hasText: `${tag} ${t}` });
  await expect(rowOf("Fin A").locator("td").nth(0)).toContainText(SUBJECT);
  await expect(rowOf("Fin A").locator("td")).toHaveText([new RegExp(`${tag} Fin A`), /6 Dec/, "3", "£60.00", "£25.00", "£35.00"]);
  await expect(rowOf("Fin B").locator("td")).toHaveText([new RegExp(`${tag} Fin B`), /7 Dec/, "1", "£15.00", "£0.00", "£15.00"]);
  await expect(rowOf("Fin C").locator("td")).toHaveText([new RegExp(`${tag} Fin C`), /8 Dec/, "1", "£0.00", "£0.00", "£0.00"]);

  // October only: 23:30 UTC on 31 Oct and 00:30 BST on 1 Oct are in, 00:30 on 1 Nov is out.
  await page.goto(`/admin/finance?from=${Y5}-10-01&to=${Y5}-10-31`);
  await expect(page.getByTestId("finance-total")).toContainText("Money taken£55.00");
  await expect(page.getByTestId("finance-total")).toContainText("Refunded£5.00");
  await expect(page.getByTestId("finance-total")).toContainText("Net£50.00");
  await expect(page.getByTestId("month-row")).toHaveCount(1);
  // September only: the booking paid at 23:30 BST on 30 Sep.
  await page.goto(`/admin/finance?from=${Y5}-09-01&to=${Y5}-09-30`);
  await expect(page.getByTestId("finance-total")).toContainText("Money taken£15.00");
  await expect(page.getByTestId("exam-money-row")).toHaveCount(1);
  // A quiet range is zero, not an error.
  await page.goto(`/admin/finance?from=${Y5}-01-01&to=${Y5}-01-31`);
  await expect(page.getByTestId("finance-total")).toContainText("Money taken£0.00");
  await expect(page.getByText("No bookings were paid in this period.").first()).toBeVisible();
  // A reversed range falls back to the financial year and says so.
  await page.goto(`/admin/finance?from=${Y5}-12-01&to=${Y5}-01-01`);
  await expect(page.locator("main [role=alert]").filter({ hasText: "Choose a valid date range" })).toBeVisible();
  await expect(page.getByLabel("From", { exact: true })).toHaveValue(`${startYear}-09-01`);
});

test("teacher_tutor_and_corrector_cannot_open_bookings_or_finance_and_have_no_links", async ({ page }) => {
  for (const role of ["teacher", "tutor", "corrector"] as const) {
    const who = await createAccount({ role });
    await clearLoginAttempts();
    await signInUI(page, who.email, who.password);
    await expect(page).toHaveURL(new RegExp(`/${role}$`));
    await expect(page.getByRole("link", { name: "Finance" })).toHaveCount(0);
    await expect(page.getByRole("link", { name: "Bookings & payments" })).toHaveCount(0);
    for (const path of ["/admin/finance", "/admin/bookings"]) {
      await page.goto(path);
      await expect(page).not.toHaveURL(/\/admin\/(finance|bookings)/);
      await expect(page.getByTestId("finance-total")).toHaveCount(0);
    }
    await page.context().clearCookies();
  }
});

test("admin_nav_has_bookings_and_finance", async ({ page }) => {
  await signInAdmin(page);
  const nav = page.getByRole("navigation").first();
  await expect(nav.getByRole("link", { name: "Bookings & payments" })).toBeVisible();
  await nav.getByRole("link", { name: "Finance" }).click();
  await expect(page).toHaveURL(/\/admin\/finance$/);
});
