import { describe, expect, it } from "vitest";
import { buildTracker, feedbackFor, termLabel, termOf } from "./progress";
import type { TestResult } from "./types";

const row = (subject: string, mark: number, date: string): TestResult => ({
  subject,
  test: "t",
  mark,
  classAverage: 0,
  highest: 0,
  lowest: 0,
  date,
  weakAreas: [],
});

const history = [
  row("Physics", 52, "15 Jun 2026"),
  row("Physics", 55, "9 Jul 2026"),
  row("Physics", 61, "16 Sep 2026"),
  row("Physics", 71, "12 Oct 2026"),
  row("Maths", 66, "17 Jun 2026"),
  row("Maths", 72, "8 Jul 2026"),
  row("Maths", 78, "15 Sep 2026"),
  row("Maths", 84, "13 Oct 2026"),
];

describe("terms", () => {
  it("places 12 Oct 2026 in Autumn 2026", () => {
    const term = termOf(new Date("2026-10-12"));
    expect(term).toEqual({ name: "Autumn", year: 2026 });
    expect(termLabel(term!)).toBe("Autumn 2026");
  });

  it("returns null during the summer break", () => {
    expect(termOf(new Date("2026-08-15"))).toBeNull();
  });
});

describe("buildTracker", () => {
  it("averages per term and forecasts the next two terms", () => {
    const t = buildTracker(history);
    expect(t.actualTerms.map(termLabel)).toEqual(["Summer 2026", "Autumn 2026"]);
    expect(t.predictedTerms.map(termLabel)).toEqual(["Spring 2027", "Summer 2027"]);
    expect(t.subjects).toEqual(["Physics", "Maths"]);
    expect(t.actual).toEqual({ Physics: [54, 66], Maths: [69, 81] });
    expect(t.forecast).toEqual({ Physics: [78, 90], Maths: [93, 100] });
    expect(t.overall).toEqual([61, 74]);
    expect(t.overallForecast).toEqual([86, 95]);
    expect(t.overallSlope).toBe(13);
  });
});

describe("feedbackFor", () => {
  it("names weak topics", () => {
    expect(feedbackFor(75, ["A"])).toBe("Strong result this term. Revise: A.");
  });
  it("handles no weak topics", () => {
    expect(feedbackFor(45, [])).toBe("This subject needs more practice. No weak topics recorded.");
  });
});
