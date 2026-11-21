import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/staff-gate", () => ({ requireStaff: vi.fn(async () => ({})) }));

const rpc = vi.fn();
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ rpc }) }));

import { saveExamAction } from "@/app/admin/exams/actions";
import { saveTeacherExamAction } from "@/app/teacher/exams/actions";

const VENUE = "11111111-2222-3333-4444-555555555555";
const NEW_ID = "99999999-2222-3333-4444-555555555555";
const form = {
  subject: "3",
  title: "Maths mock",
  paper: "Paper 1",
  format: "in_person",
  "centre.0.venue": VENUE,
  "centre.0.room": "Hall A",
  "centre.0.seats": "30",
  startDate: "2027-06-12",
  startTime: "09:00",
  duration: "90",
  price: "15.50",
  deadlineDate: "2027-06-09",
  deadlineTime: "17:00",
  homeRules: "Sit alone.",
};

function answers(rules: unknown) {
  rpc.mockImplementation(async (name: string) =>
    name === "save_exam" ? { data: { ok: true, id: NEW_ID }, error: null } : { data: rules, error: null },
  );
}

beforeEach(() => rpc.mockReset());

describe("saving an exam, then its home rules", () => {
  it("admin_rules_failure_after_save_is_a_success_with_a_warning", async () => {
    answers({ ok: false, code: "forbidden" });
    const r = await saveExamAction(form);
    // ok: the form closes, so a second Save cannot create a second exam.
    expect(r).toMatchObject({ ok: true, id: NEW_ID });
    expect(r.message).toMatch(/exam was saved, but/);
    expect(rpc.mock.calls.map((c) => c[0])).toEqual(["save_exam", "set_exam_home_rules"]);
    expect(rpc.mock.calls[1][1]).toMatchObject({ p_exam: NEW_ID, p_rules: "Sit alone." });
  });

  it("teacher_rules_failure_after_save_is_a_success_with_a_warning", async () => {
    answers(null);
    const r = await saveTeacherExamAction({ ...form, price: "" });
    expect(r).toMatchObject({ ok: true, id: NEW_ID });
    expect(r.message).toMatch(/exam was saved, but/);
  });

  it("both_succeed_gives_the_normal_message", async () => {
    answers({ ok: true, id: NEW_ID });
    expect(await saveExamAction(form)).toEqual({ ok: true, message: "Exam created as a draft. Publish it when it is ready." });
  });

  it("a_failed_save_exam_stays_a_failure_and_skips_the_rules", async () => {
    rpc.mockResolvedValue({ data: { ok: false, code: "invalid_input" }, error: null });
    const r = await saveExamAction(form);
    expect(r.ok).toBe(false);
    expect(rpc).toHaveBeenCalledTimes(1);
  });
});
