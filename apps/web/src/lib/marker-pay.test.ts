import { describe, expect, it } from "vitest";
import {
  csvCell,
  kindLabel,
  lastEndedMonth,
  monthLabel,
  parsePounds,
  parseRates,
  parseStatements,
  penceToPounds,
  pickerMonths,
  readRates,
  statementCsv,
  type Statements,
} from "./marker-pay";

const HEADER = "Month,Marker,Exam,Paper,Question group,Kind,Scripts,Rate (£),Amount (£),Fixed";

const statements: Statements = {
  month: "2027-03",
  ended: true,
  fixed: false,
  rateMissing: [{ examId: "e2", title: "Physics", paper: "Paper 2" }],
  markers: [
    {
      markerId: "m1",
      name: "Ann Archer",
      fixedAt: "2027-04-01T23:30:00Z",
      pieces: 3,
      totalPence: 3750,
      lines: [
        { examId: "e1", examTitle: "Maths, Higher", paper: "Paper 1", groupLabel: null, kind: "live", pieces: 2, ratePence: 1250, pence: 2500 },
        { examId: "e1", examTitle: "Maths, Higher", paper: "Paper 1", groupLabel: null, kind: "second", pieces: 1, ratePence: 1250, pence: 1250 },
      ],
    },
    {
      markerId: "m2",
      name: '=HYPERLINK("x")',
      fixedAt: null,
      pieces: 5,
      totalPence: null,
      lines: [
        { examId: "e1", examTitle: "Maths, Higher", paper: "Paper 1", groupLabel: "Section A", kind: "remark", pieces: 1, ratePence: 1250, pence: 1250 },
        { examId: "e2", examTitle: "Physics", paper: "Paper 2", groupLabel: null, kind: "live", pieces: 4, ratePence: null, pence: null },
      ],
    },
  ],
};

describe("money", () => {
  it("pence_to_pounds_and_back", () => {
    expect(penceToPounds(1250)).toBe("£12.50");
    expect(penceToPounds(0)).toBe("£0.00");
    expect(penceToPounds(5)).toBe("£0.05");
    expect(penceToPounds(100000)).toBe("£1,000.00");
    for (const p of [0, 1, 5, 99, 100, 1250, 99999, 100000]) expect(parsePounds(penceToPounds(p))).toBe(p);
  });

  it("parse_pounds_refuses_fractions_of_a_penny", () => {
    expect(parsePounds("12.5")).toBe(1250);
    expect(parsePounds("£3")).toBe(300);
    expect(parsePounds(" £ 7 ")).toBe(700);
    expect(parsePounds("0.05")).toBe(5);
    expect(parsePounds("1,000")).toBe(100000);
    for (const bad of ["1.999", "1.995", "0.001", "-1", "", "   ", "£", "abc", "1e3", "12.", ".5", "1,00", "+3", "3£", "99999999999999999999"]) {
      expect(parsePounds(bad), bad).toBeNull();
    }
  });

  it("rates_on_the_page_are_checked_before_saving", () => {
    expect(readRates(["12.50", "0", "£1,000"])).toEqual([1250, 0, 100000]);
    expect(readRates(["1000.01"])).toBeNull();
    expect(readRates(["12.50", ""])).toBeNull();
    expect(readRates(["1.999"])).toBeNull();
    expect(readRates([])).toBeNull();
  });
});

describe("months", () => {
  it("month_label_in_uk_time", () => {
    expect(monthLabel("2027-03-01")).toBe("March 2027");
    expect(monthLabel("2027-03")).toBe("March 2027");
    // 23:30 UTC on 31 March is 00:30 on 1 April in the UK (BST).
    expect(monthLabel("2027-03-31T23:30:00Z")).toBe("April 2027");
    // The clocks went back that morning: 23:30 UTC on 31 October is 23:30 GMT, still October.
    expect(monthLabel("2027-10-31T23:30:00Z")).toBe("October 2027");
    expect(monthLabel("2027-13-01")).toBe("");
    expect(monthLabel("soon")).toBe("");
  });

  it("last_ended_month_in_uk_time", () => {
    expect(lastEndedMonth("2026-11-25T10:00:00Z")).toBe("2026-10");
    expect(lastEndedMonth("2027-01-15T10:00:00Z")).toBe("2026-12");
    // Already 1 April in the UK, so March has ended.
    expect(lastEndedMonth("2027-03-31T23:30:00Z")).toBe("2027-03");
    expect(lastEndedMonth("2027-03-31T22:30:00Z")).toBe("2027-02");
  });

  it("picker_lists_the_last_ended_month_first", () => {
    const p = pickerMonths("2026-11-25T10:00:00Z", "2026-10");
    expect(p.current).toBe("2026-11");
    expect(p.ended[0]).toBe("2026-10");
    expect(p.ended[1]).toBe("2026-09");
    expect(p.ended).toHaveLength(24);
    expect(p.ended.at(-1)).toBe("2024-11");
    // A month asked for outside the list is added in its place.
    expect(pickerMonths("2026-11-25T10:00:00Z", "2020-01").ended.at(-1)).toBe("2020-01");
  });
});

describe("csv", () => {
  it("csv_quotes_commas_and_quotes", () => {
    expect(csvCell("Ann")).toBe('"Ann"');
    expect(csvCell("Maths, Higher")).toBe('"Maths, Higher"');
    expect(csvCell('Say "hi"')).toBe('"Say ""hi"""');
    expect(csvCell("Two\r\nlines")).toBe('"Two\r\nlines"');
    expect(csvCell(12)).toBe("12");
    expect(csvCell("")).toBe('""');
  });

  it("csv_cell_starting_with_equals_is_neutralised", () => {
    expect(csvCell('=HYPERLINK("x")')).toBe(`"'=HYPERLINK(""x"")"`);
    expect(csvCell("+1")).toBe(`"'+1"`);
    expect(csvCell("-1")).toBe(`"'-1"`);
    expect(csvCell("@SUM(A1)")).toBe(`"'@SUM(A1)"`);
    expect(csvCell("a=b")).toBe('"a=b"');
    expect(statementCsv(statements)).toContain(`"'=HYPERLINK(""x"")"`);
    expect(statementCsv(statements)).not.toMatch(/(^|,)"=HYPERLINK/m);
  });

  it("csv_has_a_total_row_per_marker_and_says_not_fixed", () => {
    const csv = statementCsv(statements);
    expect(csv.startsWith("﻿")).toBe(true);
    expect(csv.endsWith("\r\n")).toBe(true);
    expect(csv.replace(/\r\n/g, "")).not.toMatch(/[\r\n]/);
    const rows = csv.slice(1).split("\r\n").slice(0, -1);
    expect(rows[0]).toBe(HEADER);
    expect(rows.slice(1)).toEqual([
      // Fixed at 23:30 UTC on 1 April: 00:30 on 2 April in the UK.
      `"March 2027","Ann Archer","Maths, Higher","Paper 1","Whole script","First marking",2,"12.50","25.00","2 April 2027"`,
      `"March 2027","Ann Archer","Maths, Higher","Paper 1","Whole script","Second marking",1,"12.50","12.50","2 April 2027"`,
      `"March 2027","Ann Archer","Total","","","",3,"","37.50","2 April 2027"`,
      `"March 2027","'=HYPERLINK(""x"")","Maths, Higher","Paper 1","Section A","Re-marking",1,"12.50","12.50","Not fixed"`,
      `"March 2027","'=HYPERLINK(""x"")","Physics","Paper 2","Whole script","First marking",4,"Rate not set","","Not fixed"`,
      `"March 2027","'=HYPERLINK(""x"")","Total","","","",5,"","","Not fixed"`,
    ]);
    expect(rows.filter((r) => r.split(",")[2] === '"Total"')).toHaveLength(2);
    // An unknown amount is left empty, never 0.00.
    expect(csv).not.toContain('"0.00"');
  });

  it("csv_of_an_empty_month_is_the_header_alone", () => {
    expect(statementCsv({ ...statements, markers: [] })).toBe(`﻿${HEADER}\r\n`);
  });
});

describe("kinds", () => {
  it("kind_labels", () => {
    expect(kindLabel("live")).toBe("First marking");
    expect(kindLabel("second")).toBe("Second marking");
    expect(kindLabel("remark")).toBe("Re-marking");
  });
});

describe("parsers", () => {
  it("parse_statements_keeps_the_known_fields", () => {
    const r = parseStatements({
      ok: true,
      month: "2027-03-01",
      ended: true,
      fixed: false,
      rate_missing: [{ exam_id: "e2", exam_title: "Physics", paper: "Paper 2", extra: "x" }],
      markers: [
        {
          marker_id: "m2",
          name: null,
          fixed_at: null,
          pieces: 4,
          total_pence: null,
          email: "a@b.c",
          lines: [
            { exam_id: "e2", exam_title: "Physics", paper: "Paper 2", group_label: null, kind: "live", pieces: 4, rate_pence: null, pence: null, script: "S1" },
            { exam_id: "e3", exam_title: "Odd", paper: "", group_label: null, kind: "practice", pieces: 1, rate_pence: 10, pence: 10 },
          ],
        },
      ],
    });
    expect(r).toEqual({
      ok: true,
      statements: {
        month: "2027-03",
        ended: true,
        fixed: false,
        rateMissing: [{ examId: "e2", title: "Physics", paper: "Paper 2" }],
        markers: [
          {
            markerId: "m2",
            name: null,
            fixedAt: null,
            pieces: 4,
            totalPence: null,
            lines: [{ examId: "e2", examTitle: "Physics", paper: "Paper 2", groupLabel: null, kind: "live", pieces: 4, ratePence: null, pence: null }],
          },
        ],
      },
    });
  });

  it("parse_statements_refusals", () => {
    expect(parseStatements({ ok: false, code: "forbidden" })).toEqual({ ok: false, code: "forbidden" });
    expect(parseStatements(null)).toBeNull();
    expect(parseStatements({ ok: true, month: "2027-03-01" })).toBeNull();
  });

  it("parse_rates_by_mode", () => {
    expect(parseRates({ ok: true, mode: "whole", rates: [{ group_id: null, group_label: null, pence: 1250 }], fixed_pieces: 0 })).toEqual({
      mode: "whole",
      rates: [{ groupId: null, label: null, pence: 1250 }],
      fixedPieces: 0,
    });
    expect(
      parseRates({
        ok: true,
        mode: "by_question",
        rates: [
          { group_id: "g1", group_label: "Section A", pence: null },
          { group_id: "g2", group_label: "Section B", pence: 300 },
        ],
        fixed_pieces: 7,
      }),
    ).toEqual({
      mode: "by_question",
      rates: [
        { groupId: "g1", label: "Section A", pence: null },
        { groupId: "g2", label: "Section B", pence: 300 },
      ],
      fixedPieces: 7,
    });
    expect(parseRates({ ok: false, code: "forbidden" })).toBeNull();
    expect(parseRates({ ok: true, mode: "odd", rates: [], fixed_pieces: 0 })).toBeNull();
  });
});
