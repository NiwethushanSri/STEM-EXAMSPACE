// The school year has three terms. Each term's marks feed the tracker, and the tracker predicts the next terms.
import { linearForecast } from "./forecast";
import type { TestResult } from "./types";

export type TermName = "Autumn" | "Spring" | "Summer";
export type Term = { name: TermName; year: number };

// Month × 100 + day, so 9 Sep is 909 and 21 Jul is 721.
const WINDOWS: { name: TermName; from: number; to: number }[] = [
  { name: "Spring", from: 101, to: 407 }, // 1 Jan to 7 Apr
  { name: "Summer", from: 408, to: 721 }, // 8 Apr (second week) to 21 Jul (third week)
  { name: "Autumn", from: 901, to: 1231 }, // 1 Sep to 31 Dec
];

const ORDER: Record<TermName, number> = { Spring: 0, Summer: 1, Autumn: 2 };

// The term a date falls in, or null during the summer break (22 Jul to 31 Aug).
export function termOf(date: Date): Term | null {
  const code = (date.getMonth() + 1) * 100 + date.getDate();
  const w = WINDOWS.find((win) => code >= win.from && code <= win.to);
  return w ? { name: w.name, year: date.getFullYear() } : null;
}

export function termLabel(term: Term): string {
  return `${term.name} ${term.year}`;
}

// Autumn 2026 belongs to the 2026-2027 school year, and Spring and Summer 2027 belong to 2026-2027 too.
export function schoolYearOf(term: Term): string {
  const start = term.name === "Autumn" ? term.year : term.year - 1;
  return `${start}-${start + 1}`;
}

// One line of feedback from the average mark and the weak topics for a subject.
export function feedbackFor(average: number, weak: string[]): string {
  const opener =
    average >= 70 ? "Strong result this term." : average >= 50 ? "A steady result this term." : "This subject needs more practice.";
  return weak.length ? `${opener} Revise: ${weak.join(", ")}.` : `${opener} No weak topics recorded.`;
}

export function inTerm(date: string, term: Term): boolean {
  const found = termOf(new Date(date));
  return found !== null && termLabel(found) === termLabel(term);
}

export function inTermRows<T extends { date: string }>(rows: T[], term: Term): T[] {
  return rows.filter((row) => inTerm(row.date, term));
}

function rank(term: Term): number {
  return term.year * 10 + ORDER[term.name];
}

// Spring follows Autumn, Summer follows Spring, and Autumn follows Summer.
export function nextTerm(term: Term): Term {
  if (term.name === "Autumn") return { name: "Spring", year: term.year + 1 };
  if (term.name === "Spring") return { name: "Summer", year: term.year };
  return { name: "Autumn", year: term.year };
}

export type Tracker = {
  actualTerms: Term[]; // terms with results, oldest first
  predictedTerms: Term[]; // the terms after the last one with results
  subjects: string[];
  actual: Record<string, (number | null)[]>; // average mark per subject per actual term
  forecast: Record<string, number[]>; // predicted mark per subject per predicted term
  slope: Record<string, number>; // change per term for each subject
  overall: number[]; // average across subjects per actual term
  overallForecast: number[]; // average across subjects per predicted term
  overallSlope: number;
};

function mean(values: number[]): number {
  return Math.round(values.reduce((s, v) => s + v, 0) / values.length);
}

// Builds the term tracker. It needs at least two terms with results to make a forecast.
export function buildTracker(tests: TestResult[], predictedCount = 2): Tracker {
  const groups = new Map<number, Term>();
  for (const test of tests) {
    const term = termOf(new Date(test.date));
    if (term) groups.set(rank(term), term);
  }
  const actualTerms = Array.from(groups.entries())
    .sort(([a], [b]) => a - b)
    .map(([, term]) => term);

  const predictedTerms: Term[] = [];
  let cursor: Term | undefined = actualTerms[actualTerms.length - 1];
  while (cursor && predictedTerms.length < predictedCount) {
    cursor = nextTerm(cursor);
    predictedTerms.push(cursor);
  }

  const subjects = Array.from(new Set(tests.map((t) => t.subject)));
  const actual: Tracker["actual"] = {};
  const forecast: Tracker["forecast"] = {};
  const slope: Tracker["slope"] = {};

  for (const subject of subjects) {
    const perTerm = actualTerms.map((term) => {
      const marks = tests.filter((t) => t.subject === subject && inTerm(t.date, term)).map((t) => t.mark);
      return marks.length ? mean(marks) : null;
    });
    const known = perTerm.filter((v): v is number => v !== null);
    const f = linearForecast(known, predictedTerms.length);
    actual[subject] = perTerm;
    forecast[subject] = f.values;
    slope[subject] = f.slope;
  }

  // Every test counts equally, so this matches the average shown on the term report.
  const overall = actualTerms.map((term) => mean(tests.filter((t) => inTerm(t.date, term)).map((t) => t.mark)));
  const overallForecast = predictedTerms.map((_, k) =>
    mean(subjects.map((s) => forecast[s][k]).filter((v): v is number => typeof v === "number")),
  );

  return {
    actualTerms,
    predictedTerms,
    subjects,
    actual,
    forecast,
    slope,
    overall,
    overallForecast,
    overallSlope: linearForecast(overall, 0).slope,
  };
}
