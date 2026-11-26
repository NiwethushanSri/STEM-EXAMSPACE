import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/staff-gate", () => ({ requireStaff: vi.fn(async () => ({})) }));

const rpc = vi.fn();
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ rpc }) }));

import { exportCsv, fixMonth, setRates } from "@/app/admin/marking/payments/actions";

const EXAM = "11111111-1111-4111-8111-111111111111";
const GROUP = "22222222-2222-4222-8222-222222222222";
const answer = (data: unknown) => rpc.mockResolvedValueOnce({ data, error: null });

beforeEach(() => rpc.mockReset());

describe("setRates", () => {
  it("sends whole pence with the groups, and a reason only when given", async () => {
    answer({ ok: true, changed: true });
    expect(await setRates(EXAM, [{ groupId: null, pence: 1250 }])).toEqual({ ok: true, message: "Pay rates saved." });
    expect(rpc).toHaveBeenLastCalledWith("marker_rates_set", { p_exam: EXAM, p_rates: [{ group_id: null, pence: 1250 }], p_reason: null });
    answer({ ok: true, changed: false });
    expect(await setRates(EXAM, [{ groupId: GROUP, pence: 0 }], "  New rate agreed  ")).toEqual({ ok: true, message: "The pay rates are unchanged." });
    expect(rpc).toHaveBeenLastCalledWith("marker_rates_set", { p_exam: EXAM, p_rates: [{ group_id: GROUP, pence: 0 }], p_reason: "New rate agreed" });
  });

  it("refuses a rate that is not whole pence from 0 to 100,000 before calling the database", async () => {
    for (const pence of [-1, 100001, 12.5, Number.NaN]) expect((await setRates(EXAM, [{ groupId: null, pence }])).ok).toBe(false);
    expect((await setRates("nope", [{ groupId: null, pence: 1 }])).ok).toBe(false);
    expect((await setRates(EXAM, [{ groupId: "nope", pence: 1 }])).ok).toBe(false);
    expect((await setRates(EXAM, [])).ok).toBe(false);
    expect(await setRates(EXAM, [{ groupId: null, pence: 1 }], "no")).toEqual({
      ok: false,
      message: "Give a reason of 3 to 300 characters.",
      reasonRequired: true,
    });
    expect(rpc).not.toHaveBeenCalled();
  });

  it("reads a reason that is not text as no reason, without failing", async () => {
    answer({ ok: true, changed: true });
    expect(await setRates(EXAM, [{ groupId: null, pence: 1 }], 42 as unknown as string)).toEqual({ ok: true, message: "Pay rates saved." });
    expect(rpc).toHaveBeenLastCalledWith("marker_rates_set", { p_exam: EXAM, p_rates: [{ group_id: null, pence: 1 }], p_reason: null });
  });

  it("asks for a reason once pieces are fixed", async () => {
    answer({ ok: false, code: "reason_required" });
    expect(await setRates(EXAM, [{ groupId: null, pence: 1 }])).toEqual({
      ok: false,
      message: "Give a reason of 3 to 300 characters.",
      reasonRequired: true,
    });
  });
});

describe("fixMonth", () => {
  it("fixes the month's first day and says what it fixed", async () => {
    answer({ ok: true, statements: 2, pieces: 41, total_pence: 51250 });
    expect(await fixMonth("2027-03")).toEqual({ ok: true, message: "2 statements fixed for March 2027: 41 scripts, £512.50." });
    expect(rpc).toHaveBeenLastCalledWith("marker_statements_fix", { p_month: "2027-03-01" });
    answer({ ok: true, statements: 0, pieces: 0, total_pence: 0 });
    expect(await fixMonth("2027-03")).toEqual({ ok: true, message: "Nothing was left to fix for March 2027." });
  });

  it("says only that the statements are fixed when the figures cannot be read", async () => {
    for (const a of [
      { ok: true },
      { ok: true, statements: "2", pieces: 41, total_pence: 51250 },
      { ok: true, statements: 1, pieces: 1.5, total_pence: 100 },
      { ok: true, statements: 1, pieces: 1, total_pence: null },
      { ok: true, statements: 0, pieces: 0, total_pence: -1 },
    ]) {
      answer(a);
      expect(await fixMonth("2027-03")).toEqual({ ok: true, message: "The statements are fixed." });
    }
  });

  it("names the earlier month to fix first", async () => {
    answer({ ok: false, code: "earlier_month", month: "2027-02-01" });
    expect(await fixMonth("2027-03")).toEqual({ ok: false, message: "Fix February 2027 first.", month: "2027-02" });
  });

  it("names the exams without a rate", async () => {
    answer({ ok: false, code: "rate_missing", exams: [{ exam_id: EXAM, exam_title: "Physics", paper: "Paper 2" }] });
    expect(await fixMonth("2027-03")).toEqual({
      ok: false,
      message: "Set the pay rate for every exam in this month first.",
      exams: [{ examId: EXAM, title: "Physics", paper: "Paper 2" }],
    });
  });

  it("says when the month has not ended, and refuses a month that is not one", async () => {
    answer({ ok: false, code: "too_early" });
    expect(await fixMonth("2027-03")).toEqual({ ok: false, message: "This month has not ended yet." });
    expect((await fixMonth("2027-3")).ok).toBe(false);
    expect((await fixMonth("2027-03-01")).ok).toBe(false);
    expect(rpc).toHaveBeenCalledTimes(1);
  });
});

describe("exportCsv", () => {
  const month = { ok: true, month: "2027-03-01", ended: true, fixed: false, rate_missing: [], markers: [] };

  it("makes the CSV first, then records the export, then gives the CSV", async () => {
    answer(month);
    answer({ ok: true });
    const r = await exportCsv("2027-03");
    expect(r).toEqual({ ok: true, filename: "marker-statements-2027-03.csv", csv: expect.stringContaining("Month,Marker,Exam") });
    expect(rpc.mock.calls).toEqual([
      ["marker_statements_get", { p_month: "2027-03-01" }],
      ["marker_statement_exported", { p_month: "2027-03-01" }],
    ]);
  });

  it("gives no CSV when the export cannot be recorded", async () => {
    answer(month);
    answer({ ok: false, code: "forbidden" });
    expect(await exportCsv("2027-03")).toEqual({ ok: false, message: "You do not have permission to do that." });
    answer(month);
    rpc.mockResolvedValueOnce({ data: null, error: { message: "down" } });
    expect(await exportCsv("2027-03")).toEqual({ ok: false, message: "Something went wrong. Please try again." });
    expect(rpc.mock.calls.map((c) => c[0])).toEqual(["marker_statements_get", "marker_statement_exported", "marker_statements_get", "marker_statement_exported"]);
  });

  it("records nothing when the statements cannot be loaded", async () => {
    rpc.mockResolvedValueOnce({ data: null, error: { message: "down" } });
    expect((await exportCsv("2027-03")).ok).toBe(false);
    answer({ ok: false, code: "forbidden" });
    expect(await exportCsv("2027-03")).toEqual({ ok: false, message: "You do not have permission to do that." });
    // A line it cannot read makes the whole answer unreadable: no CSV of figures that do not add up.
    answer({ ...month, markers: [{ marker_id: "m1", name: "A", fixed_at: null, pieces: 1, total_pence: 10, lines: [] }] });
    expect((await exportCsv("2027-03")).ok).toBe(false);
    expect(rpc.mock.calls.map((c) => c[0])).toEqual(["marker_statements_get", "marker_statements_get", "marker_statements_get"]);
  });
});
