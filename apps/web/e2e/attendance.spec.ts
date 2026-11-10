import { expect, test, type Page } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import jsQR from "jsqr";
import { PNG } from "pngjs";
import {
  ANON_KEY,
  SUPABASE_URL,
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

// Exam-day register and index cards. Serial. Every row it creates (subjects, exams, bookings, attendance,
// photos, users) is removed again.

const tag = crypto.randomUUID().slice(0, 8);
const SUBJECT_A = `E2E Subject ${tag} A`;
const SUBJECT_B = `E2E Subject ${tag} B`;
const minutes = (n: number) => new Date(Date.now() + n * 60_000).toISOString();
let counter = 7000 + Math.floor(Math.random() * 900);
const nextIndex = () => `SE-2026-${counter++}`;

// A 1x1 JPEG: the bucket only accepts image/jpeg.
const JPEG = Buffer.from(
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=",
  "base64",
);

type Student = TestAccount & { first: string; name: string };

let admin: TestAccount;
let teacherA: TestAccount;
let teacherB: TestAccount;
let subjectA: number;
let subjectB: number;
let s1: Student; // booked on the "soon" exam, has a photo
let s2: Student; // no booking at all
let s3: Student; // booked on both exams, has a photo
let s4: Student; // booked on the started exam only, never scanned
let s5: Student; // booked on the camera exam
let soon: string; // starts in 2 hours: present
const SOON_AT = minutes(120);
let started: string; // started 30 minutes ago: late
let otherSubject: string; // subject B
let cameraExam: string;
const students: Student[] = [];

async function makeStudent(first: string, photo = false): Promise<Student> {
  const firstName = `${first}${tag}`;
  const a = await createAccount({ status: "active", firstName, indexNumber: nextIndex() });
  if (photo) {
    const up = await svc().storage.from("student-photos").upload(`${a.id}/photo.jpg`, JPEG, { contentType: "image/jpeg", upsert: true });
    if (up.error) throw new Error(`photo upload failed: ${up.error.message}`);
    const { error } = await svc().from("student_details").update({ photo_path: `${a.id}/photo.jpg` }).eq("profile_id", a.id);
    if (error) throw new Error(`photo path failed: ${error.message}`);
  }
  const s = { ...a, first: firstName, name: `${firstName} Tester` };
  students.push(s);
  return s;
}

async function makeExam(title: string, starts: string, subject: number): Promise<string> {
  const { data, error } = await svc()
    .from("exams")
    .insert({
      subject_id: subject,
      title: `${tag} ${title}`,
      paper: "Paper 1",
      format: "online",
      starts_at: starts,
      duration_minutes: 90,
      seat_limit: 20,
      price_pence: 1500,
      price_confirmed: true,
      booking_deadline: new Date(Date.parse(starts) - 3 * 86400_000).toISOString(),
      status: "published",
      created_by: admin.id,
    })
    .select("id")
    .single();
  if (error || !data) throw new Error(`exam insert failed: ${error?.message}`);
  return data.id;
}

async function book(examId: string, studentId: string, status: "paid" | "awaiting_payment" = "paid") {
  const { error } = await svc().from("bookings").insert({ exam_id: examId, student_id: studentId, booked_by: studentId, status, amount_pence: 1500 });
  if (error) throw new Error(`booking insert failed: ${error.message}`);
}

async function attendanceOf(examId: string, studentId: string) {
  const { data } = await svc().from("attendance").select("status").eq("exam_id", examId).eq("student_id", studentId).maybeSingle();
  return data?.status ?? null;
}

async function removeData() {
  const { data } = await svc().from("exams").select("id").like("title", `${tag}%`);
  const ids = (data ?? []).map((e) => e.id);
  if (ids.length) {
    await svc().from("attendance").delete().in("exam_id", ids);
    await svc().from("bookings").delete().in("exam_id", ids);
    await svc().from("exams").delete().in("id", ids);
  }
  if (students.length) await svc().storage.from("student-photos").remove(students.map((s) => `${s.id}/photo.jpg`));
}

async function signInAdmin(page: Page) {
  await signInUI(page, admin.email, admin.password);
  await expect(page).toHaveURL(/\/admin$/);
}
async function signInTeacher(page: Page, t: TestAccount) {
  await signInUI(page, t.email, t.password);
  await expect(page).toHaveURL(/\/teacher$/);
}

async function lookup(page: Page, index: string) {
  await page.getByRole("form", { name: "Student lookup" }).getByRole("textbox", { name: "Index number" }).fill(index);
  await page.getByRole("button", { name: "Look up" }).click();
}
async function expectNotFound(page: Page, path: string) {
  await page.goto(path);
  await expect(page.getByText("This page could not be found")).toBeVisible();
}
const result = (p: Page) => p.getByTestId("lookup-result");

/** Decodes the QR image of a card in Node: PNG data URL -> pixels -> jsQR. */
async function decodeCardQr(page: Page): Promise<string | null> {
  const src = await page.getByTestId("card-qr").getAttribute("src");
  expect(src).toMatch(/^data:image\/png;base64,/);
  const png = PNG.sync.read(Buffer.from(src!.split(",")[1], "base64"));
  return jsQR(new Uint8ClampedArray(png.data), png.width, png.height)?.data ?? null;
}

test.beforeAll(async () => {
  await assertNoOwner();
  admin = await createAccount({ role: "admin" });
  teacherA = await createAccount({ role: "teacher", firstName: "Tia" });
  teacherB = await createAccount({ role: "teacher", firstName: "Tom" });
  const a = await svc().from("subjects").insert({ name: SUBJECT_A, kind: "school" }).select("id").single();
  const b = await svc().from("subjects").insert({ name: SUBJECT_B, kind: "school" }).select("id").single();
  if (a.error || !a.data || b.error || !b.data) throw new Error(`subject insert failed: ${a.error?.message ?? b.error?.message}`);
  subjectA = a.data.id;
  subjectB = b.data.id;
  for (const [t, s] of [[teacherA, subjectA], [teacherB, subjectB]] as const) {
    const { error } = await svc().from("teacher_subjects").insert({ teacher_id: t.id, subject_id: s });
    if (error) throw new Error(`teacher link failed: ${error.message}`);
  }

  s1 = await makeStudent("Ada", true);
  s2 = await makeStudent("Ben");
  s3 = await makeStudent("Cleo", true);
  s4 = await makeStudent("Dev");
  s5 = await makeStudent("Eli");

  soon = await makeExam("Soon", SOON_AT, subjectA);
  started = await makeExam("Started", minutes(-30), subjectA);
  otherSubject = await makeExam("Other subject", minutes(120), subjectB);
  cameraExam = await makeExam("Camera", minutes(120), subjectA);
  await book(soon, s1.id);
  await book(soon, s3.id);
  await book(soon, s2.id, "awaiting_payment"); // an unpaid booking is not a booking
  await book(started, s3.id);
  await book(started, s4.id);
  await book(cameraExam, s5.id);
  await book(otherSubject, s1.id);

  for (const path of ["/login", "/admin/attendance", "/teacher/attendance", "/cards/x"]) {
    await fetch(`http://localhost:3005${path}`, { redirect: "manual" }).catch(() => undefined);
  }
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

test("admin_picks_an_exam_and_marks_a_typed_index_present_with_photo_and_name", async ({ page }) => {
  await signInAdmin(page);
  await page.locator("aside").getByRole("link", { name: "Attendance", exact: true }).click();
  await expect(page).toHaveURL(/\/admin\/attendance$/);
  await expect(page.getByText("Preview — sample data")).toHaveCount(0);

  const exams = page.getByTestId("attendance-exam");
  await expect(exams.filter({ hasText: `${tag} Soon` })).toHaveCount(1);
  await expect(exams.filter({ hasText: `${tag} Camera` })).toHaveCount(1);
  await exams.filter({ hasText: `${tag} Soon` }).getByRole("link").click();
  await expect(page).toHaveURL(new RegExp(`/admin/attendance/${soon}$`));
  await expect(page.getByText("Preview — sample data")).toHaveCount(0);

  // Details are in London time.
  await expect(page.getByTestId("exam-start")).toHaveText(formatLondon(SOON_AT));
  await expect(page.getByTestId("count-booked")).toHaveText("2");
  await expect(page.getByTestId("count-marked")).toHaveText("0");
  await expect(page.getByTestId("count-unmarked")).toHaveText("2");
  await expect(page.getByTestId("unmarked-list")).toContainText(s1.name);
  await expect(page.getByTestId("unmarked-list")).toContainText(s3.name);
  // The exam has not started: no close control.
  await expect(page.getByRole("button", { name: "Close register" })).toHaveCount(0);

  // Typed in lower case without hyphens: the database normalises it.
  await lookup(page, s1.indexNumber!.toLowerCase().replaceAll("-", ""));
  await expect(result(page).getByText(s1.name)).toBeVisible();
  await expect(result(page).getByRole("img", { name: `Photo of ${s1.name}` })).toBeVisible();
  expect(await attendanceOf(soon, s1.id)).toBeNull();
  await result(page).getByRole("button", { name: "Mark present" }).click();
  await expect(result(page)).toContainText("Marked Present");
  expect(await attendanceOf(soon, s1.id)).toBe("present");

  await expect(page.getByTestId("count-marked")).toHaveText("1");
  await expect(page.getByTestId("count-unmarked")).toHaveText("1");
  await expect(page.getByTestId("unmarked-list")).not.toContainText(s1.name);
  await expect(page.getByTestId("unmarked-list")).toContainText(s3.name);

  // Scanning the same student again.
  await lookup(page, s1.indexNumber!);
  await expect(result(page)).toContainText("Already marked (Present)");
  await expect(result(page).getByRole("button", { name: "Mark present" })).toHaveCount(0);
  expect(await attendanceOf(soon, s1.id)).toBe("present");
});

test("unknown_index_and_unbooked_student_are_not_marked", async ({ page }) => {
  await signInAdmin(page);
  await page.goto(`/admin/attendance/${soon}`);

  await lookup(page, "SE-1999-0001");
  await expect(result(page)).toHaveText("Not found");

  // s2 has only an unpaid booking.
  await lookup(page, s2.indexNumber!);
  await expect(result(page)).toHaveText("No paid booking");
  await expect(result(page).getByRole("button", { name: "Mark present" })).toHaveCount(0);
  expect(await attendanceOf(soon, s2.id)).toBeNull();

  // s4 is a real student with no booking on this exam.
  await lookup(page, s4.indexNumber!);
  await expect(result(page)).toHaveText("No paid booking");
  expect(await attendanceOf(soon, s4.id)).toBeNull();
});

test("late_mark_then_close_register_shows_the_absent_list", async ({ page }) => {
  await signInAdmin(page);
  await page.goto(`/admin/attendance/${started}`);
  await expect(page.getByTestId("count-booked")).toHaveText("2");

  await lookup(page, s3.indexNumber!);
  await result(page).getByRole("button", { name: "Mark present" }).click();
  // The page shows what the database decided: 30 minutes in is late.
  await expect(result(page)).toContainText("Marked Late");
  expect(await attendanceOf(started, s3.id)).toBe("late");
  await expect(page.getByTestId("count-marked")).toHaveText("1");

  await lookup(page, s3.indexNumber!);
  await expect(result(page)).toContainText("Already marked (Late)");

  // Close needs a confirm step; cancelling changes nothing.
  await page.getByRole("button", { name: "Close register" }).click();
  const dialog = page.getByRole("alertdialog", { name: "Confirm close register" });
  await expect(dialog).toBeVisible();
  await dialog.getByRole("button", { name: "Cancel" }).click();
  await expect(dialog).toHaveCount(0);
  expect(await attendanceOf(started, s4.id)).toBeNull();

  await page.getByRole("button", { name: "Close register" }).click();
  await dialog.getByRole("button", { name: "Confirm close register" }).click();
  await expect(page.getByText("Register closed. 1 marked absent.")).toBeVisible();
  expect(await attendanceOf(started, s4.id)).toBe("absent");
  const { data } = await svc().from("exams").select("status").eq("id", started).single();
  expect(data?.status).toBe("completed");

  await page.reload();
  await expect(page.getByTestId("absent-list")).toContainText(s4.name);
  await expect(page.getByTestId("absent-list")).not.toContainText(s3.name);
  await expect(page.getByRole("button", { name: "Close register" })).toHaveCount(0);
  await expect(page.getByRole("textbox", { name: "Index number" })).toHaveCount(0);
  // A completed exam stays on the picker for a while.
  await page.goto("/admin/attendance");
  await expect(page.getByTestId("attendance-exam").filter({ hasText: `${tag} Started` })).toContainText("Completed");
});

test("teacher_marks_in_own_subject_sees_no_names_and_photo_unavailable", async ({ page }) => {
  await signInTeacher(page, teacherA);
  await page.locator("aside").getByRole("link", { name: "Attendance", exact: true }).click();
  await expect(page).toHaveURL(/\/teacher\/attendance$/);
  await expect(page.getByTestId("attendance-exam").filter({ hasText: `${tag} Soon` })).toHaveCount(1);
  await expect(page.getByText(`${tag} Other subject`)).toHaveCount(0);

  await page.goto(`/teacher/attendance/${soon}`);
  await expect(page.getByTestId("count-booked")).toHaveText("2");
  // Names of students are not readable by a teacher, so the list gives none.
  await expect(page.getByTestId("unmarked-list")).not.toContainText(s3.first);
  await expect(page.getByTestId("unmarked-list")).toContainText("Names are shown to admins only");

  await lookup(page, s2.indexNumber!);
  await expect(result(page)).toHaveText("No paid booking");

  await lookup(page, s3.indexNumber!);
  await expect(result(page).getByText("Photo unavailable")).toBeVisible();
  await result(page).getByRole("button", { name: "Mark present" }).click();
  await expect(result(page)).toContainText("Marked Present");
  expect(await attendanceOf(soon, s3.id)).toBe("present");
  await expect(page.getByTestId("count-unmarked")).toHaveText("0");

  // Not an admin page.
  await page.goto("/admin/attendance");
  await expect(page).toHaveURL(/\/teacher$/);
});

test("teacher_of_another_subject_cannot_open_the_register_or_use_it", async ({ page }) => {
  await signInTeacher(page, teacherB);
  await page.goto("/teacher/attendance");
  await expect(page.getByTestId("attendance-exam").filter({ hasText: `${tag} Other subject` })).toHaveCount(1);
  await expect(page.getByTestId("attendance-exam").filter({ hasText: `${tag} Soon` })).toHaveCount(0);

  await expectNotFound(page, `/teacher/attendance/${soon}`);
  await expect(page.getByRole("textbox", { name: "Index number" })).toHaveCount(0);

  // The database refuses the calls too, whatever the page does.
  const c = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error: se } = await c.auth.signInWithPassword({ email: teacherB.email, password: teacherB.password });
  expect(se).toBeNull();
  const look = await c.rpc("attendance_lookup", { p_exam: soon, p_index: s1.indexNumber! });
  expect(look.data).toMatchObject({ ok: false, code: "forbidden" });
  const mark = await c.rpc("mark_attendance", { p_exam: soon, p_student: s1.id });
  expect(mark.data).toMatchObject({ ok: false, code: "forbidden" });
  const close = await c.rpc("close_register", { p_exam: soon });
  expect(close.data).toMatchObject({ ok: false, code: "forbidden" });
  await c.auth.signOut();
  expect(await attendanceOf(soon, s1.id)).toBe("present");
});

test("camera_scan_sends_one_lookup_per_code_and_stops_the_camera", async ({ page }) => {
  const index = s5.indexNumber!;
  await page.addInitScript((code) => {
    const w = window as unknown as Record<string, unknown>;
    w.__stopped = 0;
    w.BarcodeDetector = class {
      constructor(public options: { formats: string[] }) {
        w.__formats = options.formats;
      }
      async detect() {
        return [{ rawValue: code }];
      }
    };
    navigator.mediaDevices.getUserMedia = async (c) => {
      w.__constraints = c;
      const canvas = document.createElement("canvas");
      canvas.width = 32;
      canvas.height = 32;
      canvas.getContext("2d")!.fillRect(0, 0, 32, 32);
      const stream = canvas.captureStream(5);
      stream.getTracks().forEach((t) => {
        const stop = t.stop.bind(t);
        t.stop = () => {
          (w.__stopped as number)++;
          stop();
        };
      });
      return stream;
    };
  }, index);
  let lookups = 0;
  page.on("request", (r) => {
    if (r.method() === "POST" && r.headers()["next-action"]) lookups++;
  });

  await signInAdmin(page);
  await page.goto(`/admin/attendance/${cameraExam}`);
  await page.getByRole("button", { name: "Scan with camera" }).click();
  await expect(result(page).getByText(s5.name)).toBeVisible();
  await expect(result(page).getByRole("button", { name: "Mark present" })).toBeVisible();

  // The same code keeps being read; only one lookup goes to the server within the 3 second window.
  await page.waitForTimeout(2000);
  expect(lookups).toBe(1);
  const used = await page.evaluate(() => {
    const w = window as unknown as Record<string, unknown>;
    return { formats: w.__formats, constraints: w.__constraints };
  });
  expect(used).toEqual({ formats: ["qr_code"], constraints: { video: { facingMode: "environment" } } });

  await page.getByRole("button", { name: "Stop camera" }).click();
  await expect.poll(() => page.evaluate(() => (window as unknown as { __stopped: number }).__stopped)).toBeGreaterThan(0);
  expect(await attendanceOf(cameraExam, s5.id)).toBeNull();
});

test("without_a_camera_api_only_the_typed_input_shows", async ({ page }) => {
  await page.addInitScript(() => {
    delete (window as unknown as Record<string, unknown>).BarcodeDetector;
  });
  await signInAdmin(page);
  await page.goto(`/admin/attendance/${cameraExam}`);
  await expect(page.getByRole("textbox", { name: "Index number" })).toBeVisible();
  await expect(page.getByTestId("scanner")).toHaveCount(0);
});

test("index_card_qr_decodes_to_the_index_number_only_and_prints_a6", async ({ page }) => {
  await signInAdmin(page);
  // From the admin accounts screen.
  await page.goto(`/admin/accounts?q=${encodeURIComponent(s1.email)}`);
  const row = page.getByRole("row").filter({ hasText: s1.email });
  await row.getByRole("link", { name: "Index card" }).click();
  await expect(page).toHaveURL(new RegExp(`/cards/${s1.id}$`));

  await expect(page.getByTestId("card-name")).toHaveText(s1.name);
  await expect(page.getByTestId("card-index")).toHaveText(s1.indexNumber!);
  await expect(page.getByRole("img", { name: `Photo of ${s1.name}` })).toBeVisible();
  expect(await decodeCardQr(page)).toBe(s1.indexNumber);
  const css = (await page.locator("style").allTextContents()).join("\n");
  expect(css).toMatch(/@page\s*\{\s*size:\s*A6/);
  // Nothing else personal is printed on the card.
  const text = await page.getByLabel("Index card").innerText();
  expect(text).not.toContain(s1.email);
  expect(text).not.toContain("@");
});

test("student_opens_own_card_from_home_and_nobody_else_can", async ({ page, browser }) => {
  await signInUI(page, s3.email, s3.password);
  await expect(page).toHaveURL(/\/account\/home$/);
  await page.getByRole("link", { name: "My index card" }).click();
  await expect(page).toHaveURL(new RegExp(`/cards/${s3.id}$`));
  await expect(page.getByTestId("card-index")).toHaveText(s3.indexNumber!);
  expect(await decodeCardQr(page)).toBe(s3.indexNumber);

  // Another student's card, a malformed id, and an id that does not exist are all 404.
  for (const id of [s1.id, "not-a-uuid", "00000000-0000-4000-8000-000000000000"]) {
    await expectNotFound(page, `/cards/${id}`);
    await expect(page.getByTestId("card-index")).toHaveCount(0);
  }

  // A signed-out visitor.
  const anon = await browser.newContext();
  const p = await anon.newPage();
  await p.goto(`http://localhost:3005/cards/${s3.id}`);
  await expect(p.getByText("This page could not be found")).toBeVisible();
  await anon.close();
});

test("parent_and_teacher_cannot_open_a_card", async ({ page }) => {
  const parent = await createAccount({ role: "parent", firstName: "Pia" });
  await signInUI(page, parent.email, parent.password);
  await page.waitForURL(/\/account\/home$/);
  await expectNotFound(page, `/cards/${s1.id}`);
  await page.context().clearCookies();

  await clearLoginAttempts();
  await signInTeacher(page, teacherA);
  await expectNotFound(page, `/cards/${s1.id}`);
});
