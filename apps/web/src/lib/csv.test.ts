import { describe, expect, it } from "vitest";
import { CSV_BOM, csvCell, csvDocument } from "./csv";

describe("csv", () => {
  it("csv_cell_quotes_and_neutralises_formulas", () => {
    expect(csvCell(12)).toBe("12");
    expect(csvCell("Ann")).toBe('"Ann"');
    expect(csvCell('Say "hi"')).toBe('"Say ""hi"""');
    expect(csvCell("=1+1")).toBe(`"'=1+1"`);
    expect(csvCell("\t=1+1")).toBe(`"'\t=1+1"`);
    expect(csvCell(Number.NaN)).toBe('""');
  });

  it("csv_document_has_bom_crlf_and_a_final_line_break", () => {
    const doc = csvDocument([
      ["A", "B"],
      ["x", 1],
    ]);
    expect(doc.startsWith(CSV_BOM)).toBe(true);
    expect(doc.slice(1)).toBe('"A","B"\r\n"x",1\r\n');
  });
});
