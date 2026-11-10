import { expect, test, type Page } from "@playwright/test";
import {
  assertNoOwner,
  cleanup,
  clearLoginAttempts,
  countTestUsers,
  createAccount,
  signInUI,
  svc,
  type TestAccount,
} from "./admin";
import { formatLondon } from "../src/lib/money";

// Teacher, tutor and corrector home pages. Serial. Every row it creates is removed again.

const tag = crypto.randomUUID().slice(0, 8);
const SUBJECT_A = `E2E Subject ${tag} A`;
const SUBJECT_B = `E2E Subject ${tag} B`;
const day = (n: number) => new Date(Date.now() + n * 86400_000).toISOString();
let counter = 5000 + Math.floor(Math.random() * 900);
const nextIndex = () => `SE-2026-${counter++}`;

let admin: TestAccount;
let teacher: TestAccount;
let tutor: TestAccount;
let corrector: TestAccount;
let subjectA: number;
let subjectB: number;
const studentNames: Record<string, string> = {};
const students: Record<string, TestAccount> = {};
const SOON = day(3);
const LATER = day(6);

async function makeStudent(key: string): Promise<TestAccount> {
  const first = `${key}${tag}`;
  const a = await createAccount({ status: "active", firstName: first, indexNumber: nextIndex() });
  studentNames[key] = `${first} Tester`;
  students[key] = a;
  return a;
}

async function makeExam(title: string, starts: string, subject: number, status: "draft" | "published" | "completed", seatLimit = 20): Promise<string> {
  const { data, error } = await svc()
    .from("exams")
    .insert({
      subject_id: subject,
      title: `${tag} ${title}`,
      paper: "Paper 1",
      format: "online",
      starts_at: starts,
      duration_minutes: 90,
      seat_limit: seatLimit,
      price_pence: 1500,
      price_confirmed: true,
      booking_deadline: new Date(Date.parse(starts) - 86400_000).toISOString(),
      status,
      created_by: admin.id,
    })
    .select("id")
    .single();
  if (error || !data) throw new Error(`exam insert failed: ${error?.message}`);
  return data.id;
}

async function book(examId: string, studentId: string, status: "paid" | "awaiting_payment" | "cancel_requested" | "cancelled") {
  const { error } = await svc().from("bookings").insert({ exam_id: examId, student_id: studentId, booked_by: studentId, status, amount_pence: 1500 });
  if (error) throw new Error(`booking insert failed: ${error.message}`);
}

async function removeData() {
  const { data } = await svc().from("exams").select("id").like("title", `${tag}%`);
  const ids = (data ?? []).map((e) => e.id);
  if (ids.length) {
    await svc().from("bookings").delete().in("exam_id", ids);
    await svc().from("exams").delete().in("id", ids);
  }
}

async function signIn(page: Page, a: TestAccount, home: RegExp) {
  await signInUI(page, a.email, a.password);
  await expect(page).toHaveURL(home);
}

test.describe.configure({ mode: "serial" });

test.beforeAll(async () => {
  await assertNoOwner();
  admin = await createAccount({ role: "admin" });
  teacher = await createAccount({ role: "teacher", firstName: "Tia" });
  tutor = await createAccount({ role: "tutor", firstName: "Tut" });
  corrector = await createAccount({ role: "corrector", firstName: "Cora" });
  const a = await svc().from("subjects").insert({ name: SUBJECT_A, kind: "school" }).select("id").single();
  const b = await svc().from("subjects").insert({ name: SUBJECT_B, kind: "school" }).select("id").single();
  if (a.error || !a.data || b.error || !b.data) throw new Error(`subject insert failed: ${a.error?.message ?? b.error?.message}`);
  subjectA = a.data.id;
  subjectB = b.data.id;
  const link = await svc().from("teacher_subjects").insert({ teacher_id: teacher.id, subject_id: subjectA });
  if (link.error) throw new Error(`teacher link failed: ${link.error.message}`);

  const s1 = await makeStudent("Ada");
  const s2 = await makeStudent("Ben");
  const s3 = await makeStudent("Cleo");
  const s4 = await makeStudent("Dev"); // not assigned to the tutor
  const ts = await svc()
    .from("tutor_students")
    .insert([s1, s2, s3].map((s) => ({ tutor_id: tutor.id, student_id: s.id })));
  if (ts.error) throw new Error(`tutor link failed: ${ts.error.message}`);

  const soon = await makeExam("Soon", SOON, subjectA, "published", 10);
  const later = await makeExam("Later", LATER, subjectA, "published", 5);
  await makeExam("Draft one", day(10), subjectA, "draft");
  await makeExam("Draft two", day(11), subjectA, "draft");
  const past = await makeExam("Past", day(-3), subjectA, "completed");
  const other = await makeExam("Other subject", SOON, subjectB, "published");

  // soon: 3 seats (paid, awaiting, cancel_requested); a cancelled booking takes none.
  await book(soon, s1.id, "paid");
  await book(soon, s2.id, "awaiting_payment");
  await book(soon, s3.id, "cancel_requested");
  await book(soon, s4.id, "cancelled");
  // later: 1 seat.
  await book(later, s4.id, "paid");
  await book(past, s1.id, "paid"); // a past exam: not shown to the tutor
  await book(past, s2.id, "paid");
  await book(other, s1.id, "paid");
  await book(other, s4.id, "paid");
});
test.beforeEach(async () => {
  await clearLoginAttempts();
});
test.afterAll(async () => {
  await removeData();
  await svc().from("subjects").delete().like("name", `E2E Subject ${tag}%`);
  await cleanup();
  expect(await countTestUsers()).toBe(0);
});

test("teacher_sees_own_upcoming_exams_with_exact_seats_and_draft_count", async ({ page }) => {
  await signIn(page, teacher, /\/teacher$/);
  await expect(page.getByText("Preview — sample data")).toHaveCount(0);
  const exams = page.getByTestId("home-exam");
  await expect(exams).toHaveCount(2);
  const soon = exams.filter({ hasText: `${tag} Soon` });
  await expect(soon.getByTestId("home-seats")).toHaveText("3 of 10 seats booked");
  await expect(soon).toContainText(formatLondon(SOON));
  await expect(exams.filter({ hasText: `${tag} Later` }).getByTestId("home-seats")).toHaveText("1 of 5 seats booked");
  await expect(page.getByText(`${tag} Other subject`)).toHaveCount(0);
  await expect(page.getByText(`${tag} Past`)).toHaveCount(0);
  await expect(page.getByText(`${tag} Draft`)).toHaveCount(0);
  await expect(page.getByText("Draft exams").locator("xpath=following-sibling::div")).toHaveText("2");
  await expect(page.getByText("Upcoming exams", { exact: true }).locator("xpath=following-sibling::div")).toHaveText("2");
  // No prices and no student names.
  await expect(page.getByText("£")).toHaveCount(0);
  for (const n of Object.values(studentNames)) await expect(page.getByText(n)).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Manage exams" })).toHaveAttribute("href", "/teacher/exams");
  await expect(page.getByRole("link", { name: "Attendance registers" })).toHaveAttribute("href", "/teacher/attendance");
});

test("tutor_sees_exactly_assigned_students_upcoming_bookings", async ({ page }) => {
  await signIn(page, tutor, /\/tutor$/);
  await expect(page.getByText("Preview — sample data")).toHaveCount(0);
  const rows = page.getByTestId("tutor-booking");
  // Ada twice (this subject and the other subject, both paid), Ben awaiting payment, Cleo cancel requested; Dev is not assigned.
  await expect(rows).toHaveCount(4);
  await expect(rows.filter({ hasText: studentNames.Ada })).toHaveCount(2);
  await expect(rows.filter({ hasText: studentNames.Ben })).toHaveCount(1);
  await expect(rows.filter({ hasText: studentNames.Ben })).toContainText("Awaiting payment");
  await expect(rows.filter({ hasText: studentNames.Cleo })).toHaveCount(1);
  await expect(rows.filter({ hasText: studentNames.Cleo })).toContainText("Cancellation requested");
  await expect(rows.filter({ hasText: studentNames.Ada }).filter({ hasText: SUBJECT_A })).toContainText("Paid");
  await expect(rows.filter({ hasText: studentNames.Ada }).filter({ hasText: SUBJECT_B })).toContainText(formatLondon(SOON));
  await expect(page.getByText(studentNames.Dev)).toHaveCount(0);
  await expect(page.getByText("Exam details unavailable")).toHaveCount(0);
  await expect(page.getByText(`${tag} Past`)).toHaveCount(0);
  await expect(page.getByText("£")).toHaveCount(0);
});

test("corrector_sees_the_placeholder", async ({ page }) => {
  await signIn(page, corrector, /\/corrector$/);
  await expect(page.getByText("Marking arrives in the next update")).toBeVisible();
  await expect(page.getByText("Preview — sample data")).toHaveCount(0);
});

test("each_role_is_redirected_away_from_the_others_homes", async ({ page }) => {
  const homes = { teacher: /\/teacher$/, tutor: /\/tutor$/, corrector: /\/corrector$/ };
  const people = [
    ["teacher", teacher],
    ["tutor", tutor],
    ["corrector", corrector],
  ] as const;
  for (const [role, acct] of people) {
    await signIn(page, acct, homes[role]);
    for (const other of ["teacher", "tutor", "corrector"] as const) {
      if (other === role) continue;
      await page.goto(`/${other}`);
      await expect(page).toHaveURL(homes[role]);
    }
    await page.context().clearCookies();
    await clearLoginAttempts();
  }
});
