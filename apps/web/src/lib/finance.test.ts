import { describe, expect, it } from "vitest";
import { financialYear, monthLabel, parseDateParam, readMoneyTotals, resolveRange } from "./finance";

describe("financialYear (London, 1 Sep to 31 Aug)", () => {
  it("mid-year", () => {
    expect(financialYear(new Date("2026-11-10T12:00:00Z"))).toEqual({ from: "2026-09-01", to: "2027-08-31" });
    expect(financialYear(new Date("2027-03-01T12:00:00Z"))).toEqual({ from: "2026-09-01", to: "2027-08-31" });
  });
  it("starts on 1 Sep London time", () => {
    // 23:30 UTC on 31 Aug is 00:30 BST on 1 Sep.
    expect(financialYear(new Date("2026-08-31T23:30:00Z"))).toEqual({ from: "2026-09-01", to: "2027-08-31" });
    expect(financialYear(new Date("2026-08-31T22:30:00Z"))).toEqual({ from: "2025-09-01", to: "2026-08-31" });
  });
  it("ends on 31 Aug London time", () => {
    expect(financialYear(new Date("2027-08-31T22:59:00Z"))).toEqual({ from: "2026-09-01", to: "2027-08-31" });
  });
});

describe("parseDateParam", () => {
  it("accepts real dates only", () => {
    expect(parseDateParam("2031-10-05")).toBe("2031-10-05");
    expect(parseDateParam(["2031-10-05", "x"])).toBe("2031-10-05");
    expect(parseDateParam("2031-02-30")).toBeNull();
    expect(parseDateParam("2031-13-01")).toBeNull();
    expect(parseDateParam("31/10/2031")).toBeNull();
    expect(parseDateParam("1999-01-01")).toBeNull();
    expect(parseDateParam(undefined)).toBeNull();
  });
});

describe("resolveRange", () => {
  const now = new Date("2026-11-10T12:00:00Z");
  it("uses the params when valid", () => {
    expect(resolveRange("2031-10-01", "2031-11-30", now)).toEqual({ from: "2031-10-01", to: "2031-11-30", usedDefault: false, invalid: false });
  });
  it("defaults to the financial year when absent", () => {
    expect(resolveRange(undefined, undefined, now)).toEqual({ from: "2026-09-01", to: "2027-08-31", usedDefault: true, invalid: false });
  });
  it("defaults and flags bad or reversed input", () => {
    expect(resolveRange("2031-11-30", "2031-10-01", now)).toMatchObject({ from: "2026-09-01", usedDefault: true, invalid: true });
    expect(resolveRange("nope", "2031-10-01", now)).toMatchObject({ usedDefault: true, invalid: true });
  });
});

describe("monthLabel", () => {
  it("names the month", () => {
    expect(monthLabel("2031-10")).toBe("October 2031");
    expect(monthLabel("bad")).toBe("bad");
  });
});

describe("readMoneyTotals", () => {
  const ok = {
    ok: true,
    months: [{ month: "2031-10", taken: 100, refunded: 0, net: 100, bookings: 1 }],
    exams: [{ examId: "e", subject: "S", title: "T", startsAt: "2031-10-01T00:00:00+00:00", taken: 100, refunded: 0, net: 100, bookings: 1 }],
    total: { taken: 100, refunded: 0, net: 100 },
  };
  it("accepts a well-formed answer", () => {
    expect(readMoneyTotals(ok)?.total.net).toBe(100);
  });
  it("rejects odd answers", () => {
    expect(readMoneyTotals(null)).toBeNull();
    expect(readMoneyTotals({ ...ok, total: { taken: "1", refunded: 0, net: 0 } })).toBeNull();
    expect(readMoneyTotals({ ...ok, months: [{ month: "x" }] })).toBeNull();
    expect(readMoneyTotals({ ...ok, exams: "no" })).toBeNull();
  });
});
