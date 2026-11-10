import { describe, expect, it } from "vitest";
import { formatLondon, formatPence } from "./money";

describe("formatPence", () => {
  it("formats pence as pounds", () => {
    expect(formatPence(1500)).toBe("£15.00");
    expect(formatPence(1)).toBe("£0.01");
    expect(formatPence(99)).toBe("£0.99");
    expect(formatPence(123456)).toBe("£1,234.56");
  });
  it("shows Free for zero", () => {
    expect(formatPence(0)).toBe("Free");
  });
});

describe("formatLondon", () => {
  it("shows BST in summer (UTC+1)", () => {
    expect(formatLondon("2027-06-12T08:00:00Z")).toBe("Sat 12 Jun 2027, 09:00");
  });
  it("shows GMT in winter (UTC+0)", () => {
    expect(formatLondon("2027-12-11T09:00:00Z")).toBe("Sat 11 Dec 2027, 09:00");
  });
  it("crosses midnight into the next London day in summer", () => {
    expect(formatLondon("2027-06-12T23:30:00Z")).toBe("Sun 13 Jun 2027, 00:30");
  });
  it("handles the clock change days", () => {
    expect(formatLondon("2027-03-28T00:59:00Z")).toBe("Sun 28 Mar 2027, 00:59");
    expect(formatLondon("2027-03-28T01:00:00Z")).toBe("Sun 28 Mar 2027, 02:00");
    expect(formatLondon("2027-10-31T00:30:00Z")).toBe("Sun 31 Oct 2027, 01:30");
    expect(formatLondon("2027-10-31T01:30:00Z")).toBe("Sun 31 Oct 2027, 01:30");
  });
  it("returns empty text for an invalid timestamp", () => {
    expect(formatLondon("nope")).toBe("");
  });
});
