/** One CSV cell. A number as it is. A text in double quotes with its quotes doubled; a text that starts with =, +, -, @,
 * a tab or a carriage return gets a leading ' first, so a spreadsheet does not read it as a formula. */
export function csvCell(value: string | number): string {
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : '""';
  const safe = /^[=+\-@\t\r]/.test(value) ? `'${value}` : value;
  return `"${safe.replace(/"/g, '""')}"`;
}

/** The UTF-8 byte-order mark, so a spreadsheet reads the file as UTF-8. */
export const CSV_BOM = "﻿";

/** Lines of cells as a CSV file: the byte-order mark, every cell through csvCell, CRLF between lines and after the last. */
export function csvDocument(lines: (string | number)[][]): string {
  return `${CSV_BOM}${lines.map((l) => l.map(csvCell).join(",")).join("\r\n")}\r\n`;
}
