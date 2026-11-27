import { describe, expect, it } from "vitest";
import {
  ordinal,
  parseExport,
  parseResults,
  publishAtCheck,
  resultsCsv,
  stateText,
  validateBoundaries,
  type ExportRow,
} from "./results-admin";

const ROW = {
  booking_id: "b2",
  name: "Ann Lee",
  index_number: "S-1",
  sitting: "centre",
  status: "present",
  status_set: false,
  status_reason: null,
  total: 71.5,
  percentage: 71.5,
  grade: "A",
  rank: 1,
  rank_cohort: 5,
  version: 0,
  remarked: false,
};

const RAW = {
  ok: true,
  state: "prepared",
  version: 3,
  approval: { approved_at: "2026-11-20T10:00:00Z", stale: false },
  boundaries: [
    { grade: "A", min_mark: 70 },
    { grade: "B", min_mark: 55.5 },
  ],
  max_total: 100,
  counts: { present: 6, absent: 1, withdrawn: 0, incomplete: 0, disqualified: 0 },
  cohort: { present: 6, average: 61.2, lower_quartile: 50, upper_quartile: 72.5, questions: [] },
  bands: Array.from({ length: 10 }, (_, i) => ({ from: i * 10, to: i * 10 + 10, count: i === 6 ? 6 : 0 })),
  grades: [
    { grade: "A", all: 2, centre: 1, home: 1 },
    { grade: "U", all: 4, centre: 4, home: 0 },
  ],
  missing: [{ booking_id: "b1", name: null, index_number: null }],
  rows: [ROW],
  more: false,
  publish_at: null,
  first_published_at: null,
  published_at: null,
  publish_failed_at: null,
  publish_failed_reason: null,
  withdrawn_at: null,
  withdraw_reason: null,
};

type In = { grade: string; mark: string };

describe("validateBoundaries", () => {
  const run = (rows: In[], max: number | null = 100) => validateBoundaries(rows, max);

  it("validate_boundaries_rules", () => {
    expect(run([{ grade: " A ", mark: "70" }, { grade: "B", mark: "55.5" }])).toEqual({
      ok: true,
      grades: [
        { grade: "A", min_mark: 70 },
        { grade: "B", min_mark: 55.5 },
      ],
    });
    expect(run([])).toEqual({ ok: true, grades: [] });
    const bad = (rows: In[], max: number | null = 100) => expect(run(rows, max).ok).toBe(false);
    bad([{ grade: "", mark: "70" }]);
    bad([{ grade: "ABCDEFGHIJK", mark: "70" }]);
    bad([{ grade: "A", mark: "" }]);
    bad([{ grade: "A", mark: "abc" }]);
    bad([{ grade: "A", mark: "-1" }]);
    bad([{ grade: "A", mark: "70.55" }]);
    bad([{ grade: "A", mark: "101" }]);
    bad([{ grade: "A", mark: "70" }, { grade: "B", mark: "70" }]); // not strictly decreasing
    bad([{ grade: "A", mark: "60" }, { grade: "B", mark: "70" }]); // wrong way round
    bad([{ grade: "A", mark: "70" }, { grade: "a", mark: "60" }]); // same label
    bad(Array.from({ length: 16 }, (_, i) => ({ grade: `G${i}`, mark: String(90 - i) }))); // more than 15
    bad([{ grade: "A", mark: "70" }], null); // the paper's total is not known
    expect(run(Array.from({ length: 15 }, (_, i) => ({ grade: `G${i}`, mark: String(90 - i) }))).ok).toBe(true);
    expect(run([{ grade: "A", mark: "100" }]).ok).toBe(true);
    expect(run([{ grade: "A", mark: "0" }]).ok).toBe(true);
  });
});

describe("resultsCsv", () => {
  const row = (over: Partial<ExportRow>): ExportRow => ({
    bookingId: "b",
    name: "Ann Lee",
    indexNumber: "S-1",
    sitting: "centre",
    status: "present",
    total: 7.5,
    maxTotal: 10,
    percentage: 75,
    grade: "A",
    rank: 1,
    marks: [
      { label: "1", mark: 4, notAttempted: false },
      { label: "2(a)", mark: null, notAttempted: true },
      { label: "2(b)", mark: null, notAttempted: false },
    ],
    ...over,
  });

  it("results_csv_header_and_cells", () => {
    const csv = resultsCsv([
      row({}),
      row({ name: "=HYPERLINK(1)", status: "absent", total: null, percentage: null, grade: null, rank: null, marks: [] }),
      row({ name: "\tTab" }),
    ]);
    expect(csv.startsWith("﻿")).toBe(true);
    const lines = csv.slice(1).split("\r\n");
    expect(lines.at(-1)).toBe("");
    expect(lines[0]).toBe('"Name","Index number","Mode","Status","Total","Maximum","Percentage","Grade","Rank","1","2(a)","2(b)"');
    expect(lines[1]).toBe('"Ann Lee","S-1","Centre","Present",7.5,10,75,"A",1,4,"NR",""');
    expect(lines[2]).toBe(`"'=HYPERLINK(1)","S-1","Centre","Absent","",10,"","","","","",""`);
    expect(lines[3].startsWith(`"'\tTab"`)).toBe(true);
  });

  it("results_csv_with_no_rows_is_just_the_header", () => {
    expect(resultsCsv([]).slice(1)).toBe('"Name","Index number","Mode","Status","Total","Maximum","Percentage","Grade","Rank"\r\n');
  });
});

describe("ordinal", () => {
  it("ordinal_suffixes", () => {
    const want: [number, string][] = [
      [1, "1st"],
      [2, "2nd"],
      [3, "3rd"],
      [4, "4th"],
      [10, "10th"],
      [11, "11th"],
      [12, "12th"],
      [13, "13th"],
      [21, "21st"],
      [22, "22nd"],
      [23, "23rd"],
      [101, "101st"],
      [111, "111th"],
      [112, "112th"],
      [113, "113th"],
    ];
    for (const [n, s] of want) expect(ordinal(n)).toBe(s);
  });
});

describe("parseResults", () => {
  it("parse_results_reads_the_known_fields", () => {
    const r = parseResults(RAW);
    expect(r?.state).toBe("prepared");
    expect(r?.version).toBe(3);
    expect(r?.boundaries).toEqual([
      { grade: "A", minMark: 70 },
      { grade: "B", minMark: 55.5 },
    ]);
    expect(r?.cohort?.lowerQuartile).toBe(50);
    expect(r?.rows[0]).toMatchObject({ bookingId: "b2", name: "Ann Lee", rank: 1, rankCohort: 5, total: 71.5 });
    expect(r?.missing[0]).toMatchObject({ bookingId: "b1", name: null });
    expect(r?.bands).toHaveLength(10);
    expect(parseResults({ ...RAW, cohort: null })?.cohort).toBeNull();
    expect(parseResults({ ...RAW, state: "none", approval: { approved_at: null, stale: false } })?.approvedAt).toBeNull();
  });

  it("parse_results_rejects_unexpected_shapes", () => {
    expect(parseResults(null)).toBeNull();
    expect(parseResults("x")).toBeNull();
    expect(parseResults([])).toBeNull();
    expect(parseResults({ ok: false, code: "forbidden" })).toBeNull();
    expect(parseResults({ ...RAW, state: "weird" })).toBeNull();
    expect(parseResults({ ...RAW, version: "3" })).toBeNull();
    expect(parseResults({ ...RAW, rows: "no" })).toBeNull();
    expect(parseResults({ ...RAW, counts: null })).toBeNull();
    expect(parseResults({ ...RAW, rows: [{ ...ROW, status: "nope" }] })).toBeNull();
    expect(parseResults({ ...RAW, rows: [{ ...ROW, booking_id: 5 }] })).toBeNull();
  });
});

describe("parseExport", () => {
  it("reads_rows_and_filename_and_rejects_bad_shapes", () => {
    const raw = { ok: true, filename: "results-X.csv", rows: [{ ...ROW, max_total: 100, marks: [{ label: "1", mark: 4, not_attempted: false }] }] };
    expect(parseExport(raw)?.filename).toBe("results-X.csv");
    expect(parseExport(raw)?.rows[0].marks[0]).toEqual({ label: "1", mark: 4, notAttempted: false });
    expect(parseExport({ ...raw, filename: 5 })).toBeNull();
    expect(parseExport({ ...raw, rows: {} })).toBeNull();
    expect(parseExport(null)).toBeNull();
  });
});

describe("stateText", () => {
  it("says_where_the_results_stand", () => {
    expect(stateText({ state: "none", publishAt: null, publishedAt: null })).toBe("Not prepared");
    expect(stateText({ state: "prepared", publishAt: null, publishedAt: null })).toBe("Prepared");
    expect(stateText({ state: "scheduled", publishAt: "2027-06-12T08:00:00Z", publishedAt: null })).toBe("Publishing at Sat 12 Jun 2027, 09:00 (UK time)");
    expect(stateText({ state: "published", publishAt: null, publishedAt: "2027-01-15T12:00:00Z" })).toBe("Published Fri 15 Jan 2027, 12:00 (UK time)");
    expect(stateText({ state: "withdrawn", publishAt: null, publishedAt: null })).toBe("Withdrawn");
  });
});

describe("publishAtCheck", () => {
  const now = Date.parse("2027-06-01T10:00:00Z"); // 11:00 in London (BST)
  it("empty_means_publish_now", () => {
    expect(publishAtCheck("", "", now)).toEqual({ ok: true, at: null });
  });
  it("needs_both_a_date_and_a_real_time", () => {
    expect(publishAtCheck("2027-06-02", "", now).ok).toBe(false);
    expect(publishAtCheck("", "09:00", now).ok).toBe(false);
    expect(publishAtCheck("2027-02-30", "09:00", now).ok).toBe(false);
  });
  it("not_more_than_a_minute_past_and_not_more_than_30_days_ahead_in_uk_time", () => {
    expect(publishAtCheck("2027-06-01", "11:00", now).ok).toBe(true);
    expect(publishAtCheck("2027-06-01", "10:59", now).ok).toBe(true); // a minute ago
    expect(publishAtCheck("2027-06-01", "10:58", now).ok).toBe(false);
    expect(publishAtCheck("2027-07-01", "11:00", now).ok).toBe(true); // exactly 30 days
    expect(publishAtCheck("2027-07-01", "11:01", now).ok).toBe(false);
  });
  it("returns_the_utc_instant_the_uk_time_means", () => {
    expect(publishAtCheck("2027-06-12", "09:00", now)).toEqual({ ok: true, at: "2027-06-12T08:00:00.000Z" });
    expect(publishAtCheck("2027-01-12", "09:00", Date.parse("2027-01-01T00:00:00Z"))).toEqual({ ok: true, at: "2027-01-12T09:00:00.000Z" });
  });
});
