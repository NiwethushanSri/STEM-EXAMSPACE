import { describe, expect, it } from "vitest";
import { londonLocalToUtc, utcToLondonParts } from "./london-time";

describe("londonLocalToUtc", () => {
  it("reads winter times as GMT", () => {
    expect(londonLocalToUtc("2027-01-16", "09:00")).toBe("2027-01-16T09:00:00.000Z");
    expect(londonLocalToUtc("2027-12-04", "23:59")).toBe("2027-12-04T23:59:00.000Z");
  });
  it("reads summer times as BST", () => {
    expect(londonLocalToUtc("2027-06-12", "09:00")).toBe("2027-06-12T08:00:00.000Z");
    expect(londonLocalToUtc("2027-06-12", "00:30")).toBe("2027-06-11T23:30:00.000Z");
  });
  it("switches at the March 2027 clock change (28 March, 01:00 UTC)", () => {
    expect(londonLocalToUtc("2027-03-28", "00:59")).toBe("2027-03-28T00:59:00.000Z");
    expect(londonLocalToUtc("2027-03-28", "02:00")).toBe("2027-03-28T01:00:00.000Z");
    expect(londonLocalToUtc("2027-03-28", "09:00")).toBe("2027-03-28T08:00:00.000Z");
    expect(londonLocalToUtc("2027-03-27", "09:00")).toBe("2027-03-27T09:00:00.000Z");
  });
  it("rejects a time that does not exist when the clocks go forward", () => {
    expect(londonLocalToUtc("2027-03-28", "01:00")).toBeNull();
    expect(londonLocalToUtc("2027-03-28", "01:30")).toBeNull();
  });
  it("switches at the October 2027 clock change (31 October, 01:00 UTC)", () => {
    expect(londonLocalToUtc("2027-10-30", "09:00")).toBe("2027-10-30T08:00:00.000Z");
    expect(londonLocalToUtc("2027-10-31", "00:30")).toBe("2027-10-30T23:30:00.000Z");
    expect(londonLocalToUtc("2027-10-31", "02:00")).toBe("2027-10-31T02:00:00.000Z");
    expect(londonLocalToUtc("2027-10-31", "09:00")).toBe("2027-10-31T09:00:00.000Z");
  });
  it("takes the first (BST) instant of a time that happens twice when the clocks go back", () => {
    expect(londonLocalToUtc("2027-10-31", "01:30")).toBe("2027-10-31T00:30:00.000Z");
  });
  it("rejects malformed input and impossible dates", () => {
    const bad: [string, string][] = [
      ["", ""],
      ["2027-6-12", "09:00"],
      ["2027-06-12", "9:00"],
      ["2027-02-30", "09:00"],
      ["2027-13-01", "09:00"],
      ["2027-06-12", "24:00"],
      ["2027-06-12", "09:60"],
      ["12/06/2027", "09:00"],
    ];
    for (const [d, t] of bad) expect(londonLocalToUtc(d, t), `${d} ${t}`).toBeNull();
  });
});

describe("utcToLondonParts", () => {
  it("round trips either side of a clock change", () => {
    const cases: [string, string][] = [
      ["2027-03-27", "09:00"],
      ["2027-03-28", "09:00"],
      ["2027-10-30", "09:00"],
      ["2027-10-31", "09:00"],
      ["2027-06-12", "00:30"],
    ];
    for (const [d, t] of cases) {
      const iso = londonLocalToUtc(d, t)!;
      expect(utcToLondonParts(iso)).toEqual({ date: d, time: t });
    }
  });
  it("returns blanks for a bad timestamp", () => {
    expect(utcToLondonParts("nope")).toEqual({ date: "", time: "" });
  });
});
