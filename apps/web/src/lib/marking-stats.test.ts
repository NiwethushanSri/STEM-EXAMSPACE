import { describe, expect, it } from "vitest";
import {
  agreementText,
  comparisonText,
  differenceText,
  gapText,
  NO_OTHERS_TEXT,
  parseStats,
  percentText,
  secondsText,
  statsNote,
} from "./marking-stats";

const M1 = "11111111-1111-4111-8111-111111111111";
const M2 = "22222222-2222-4222-8222-222222222222";

describe("statsNote", () => {
  it("stats_note_texts", () => {
    expect(statsNote("fast")).toBe("Much faster than usual for this exam.");
    expect(statsNote("full_marks")).toBe("Many scripts at full marks.");
    expect(statsNote("mean_apart")).toBe("Average mark is far from the other markers'.");
    expect(statsNote("something_else")).toBe("");
    expect(statsNote("toString")).toBe("");
  });
});

describe("secondsText", () => {
  it("seconds_text_cases", () => {
    expect(secondsText(250)).toBe("4 min 10 s");
    expect(secondsText(45)).toBe("45 s");
    expect(secondsText(0)).toBe("0 s");
    expect(secondsText(60)).toBe("1 min");
    expect(secondsText(59.6)).toBe("1 min");
    expect(secondsText(3600)).toBe("1 h");
    expect(secondsText(3725)).toBe("1 h 2 min");
    expect(secondsText(null)).toBe("—");
    expect(secondsText(-5)).toBe("—");
    expect(secondsText(Number.NaN)).toBe("—");
  });
});

describe("the table's words", () => {
  it("difference_text_cases", () => {
    expect(differenceText(12.5)).toBe("12.5 points above the others");
    expect(differenceText(-3)).toBe("3 points below the others");
    expect(differenceText(1)).toBe("1 point above the others");
    expect(differenceText(-1)).toBe("1 point below the others");
    expect(differenceText(0)).toBe("The same as the others");
    expect(differenceText(null)).toBe("");
  });

  it("comparison_text_cases", () => {
    expect(NO_OTHERS_TEXT).toBe("No other markers to compare with.");
    expect(comparisonText({ difference: 0, cohortHasOthers: false })).toBe("No other markers to compare with.");
    expect(comparisonText({ difference: 0, cohortHasOthers: true })).toBe("The same as the others");
    expect(comparisonText({ difference: -4.5, cohortHasOthers: true })).toBe("4.5 points below the others");
    expect(comparisonText({ difference: null, cohortHasOthers: false })).toBe("");
  });

  it("gap_text_cases", () => {
    expect(gapText(1)).toBe("Totals 1 mark apart on average");
    expect(gapText(1.5)).toBe("Totals 1.5 marks apart on average");
    expect(gapText(0)).toBe("Totals 0 marks apart on average");
    expect(gapText(0.96)).toBe("Totals 1 mark apart on average");
    expect(gapText(3.64)).toBe("Totals 3.6 marks apart on average");
  });

  it("agreement_and_percent_text_cases", () => {
    expect(agreementText(18, 20)).toBe("18 of 20 within tolerance");
    expect(agreementText(0, 1)).toBe("0 of 1 within tolerance");
    expect(agreementText(0, 0)).toBe("—");
    expect(percentText(72.5)).toBe("72.5%");
    expect(percentText(80)).toBe("80%");
    expect(percentText(null)).toBe("—");
  });
});

describe("parseStats", () => {
  it("parse_stats_keeps_the_known_fields", () => {
    const r = parseStats({
      ok: true,
      tolerance_percent: 10,
      exam: { pieces: 30, mean_percent: 61.2, median_seconds: 250, script_number: "S-AB-0001" },
      markers: [
        {
          marker_id: M1,
          name: "Aurelius Firstley",
          pieces: 12,
          mean_percent: 70,
          cohort_mean_percent: 60,
          cohort_has_others: true,
          difference: 10,
          second: { compared: 3, within: 2, mean_gap: 1.5 },
          seeds: { done: 2, within: 1 },
          practice: { done: 1, within: 1 },
          median_seconds: 80,
          sent_back: 1,
          notes: ["fast", "unknown", 3, "full_marks"],
          index_number: "SE-2099-0001",
        },
        { marker_id: "not-a-uuid", name: "Nobody", pieces: 1 },
        { marker_id: M2, name: null, pieces: 0, mean_percent: null, second: null, notes: null },
      ],
    });
    expect(r).toEqual({
      ok: true,
      stats: {
        tolerancePercent: 10,
        exam: { pieces: 30, meanPercent: 61.2, medianSeconds: 250 },
        markers: [
          {
            markerId: M1,
            name: "Aurelius Firstley",
            pieces: 12,
            meanPercent: 70,
            cohortMeanPercent: 60,
            cohortHasOthers: true,
            difference: 10,
            second: { compared: 3, within: 2, meanGap: 1.5 },
            seeds: { done: 2, within: 1 },
            practice: { done: 1, within: 1 },
            medianSeconds: 80,
            sentBack: 1,
            notes: ["fast", "full_marks"],
          },
          {
            markerId: M2,
            name: "Marker 22222222",
            pieces: 0,
            meanPercent: null,
            cohortMeanPercent: null,
            cohortHasOthers: false,
            difference: null,
            second: { compared: 0, within: 0, meanGap: null },
            seeds: { done: 0, within: 0 },
            practice: { done: 0, within: 0 },
            medianSeconds: null,
            sentBack: 0,
            notes: [],
          },
        ],
      },
    });
    expect(JSON.stringify(r)).not.toContain("SE-2099");
    expect(JSON.stringify(r)).not.toContain("S-AB-0001");
  });

  it("parse_stats_refusals", () => {
    expect(parseStats({ ok: false, code: "forbidden" })).toEqual({ ok: false, code: "forbidden" });
    expect(parseStats({ ok: false })).toEqual({ ok: false, code: "internal" });
    expect(parseStats(null)).toBeNull();
    expect(parseStats({ ok: true, markers: "x" })).toBeNull();
  });
});
