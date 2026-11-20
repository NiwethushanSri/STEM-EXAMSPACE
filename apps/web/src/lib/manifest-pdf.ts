import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "pdf-lib";
import QRCode from "qrcode";
import { safe } from "@/lib/print-pack";

export type ManifestRow = {
  index_number: string | null;
  name: string;
  /** present, late, absent or not_marked */
  attendance: string;
  /** Extra sheets counted; null when absent, not marked or not counted yet. */
  extra_sheets: number | null;
};

export type ManifestData = {
  /** M-<exam code>-<nn>; printed as text and as the QR code. */
  number: string;
  examTitle: string;
  examCode: string;
  centre: string;
  date: string;
  madeAt: string;
  rows: ManifestRow[];
};

const A4: [number, number] = [595.28, 841.89];
const LEFT = 48;
const RIGHT = 595.28 - 48;
const ROW = 18;
const TOP_ROWS = 650;
const BOTTOM = 70;
const SIGNATURE_HEIGHT = 190;
const ink = rgb(0.1, 0.1, 0.1);
const grey = rgb(0.4, 0.4, 0.4);

const ATTENDANCE: Record<string, string> = { present: "Present", late: "Late", absent: "Absent", not_marked: "Not marked" };

/** What the Sheets column says for one row. */
export function sheetsText(r: Pick<ManifestRow, "attendance" | "extra_sheets">): string {
  if (r.attendance === "absent") return "Absent";
  if (r.attendance !== "present" && r.attendance !== "late") return "Not marked";
  if (r.extra_sheets === null) return "Not counted";
  return `Booklet + ${r.extra_sheets} extra sheet${r.extra_sheets === 1 ? "" : "s"}`;
}

/** The QR code as one filled square per dark module, with a white quiet zone around it. */
function drawQr(page: PDFPage, text: string, x: number, y: number, size: number) {
  const { size: n, data } = QRCode.create(text, { errorCorrectionLevel: "M" }).modules;
  const cell = size / (n + 2);
  page.drawRectangle({ x, y, width: size, height: size, color: rgb(1, 1, 1) });
  for (let row = 0; row < n; row++) {
    for (let col = 0; col < n; col++) {
      if (!data[row * n + col]) continue;
      page.drawRectangle({ x: x + (col + 1) * cell, y: y + size - (row + 2) * cell, width: cell, height: cell, color: rgb(0, 0, 0) });
    }
  }
}

function header(page: PDFPage, m: ManifestData, font: PDFFont, bold: PDFFont, pageNo: number, pages: number) {
  page.drawText("Collection manifest", { x: LEFT, y: 790, size: 20, font: bold, color: ink });
  page.drawText(safe(m.number), { x: LEFT, y: 764, size: 14, font: bold, color: ink });
  const lines: [string, string][] = [
    ["Exam", m.examTitle],
    ["Exam code", m.examCode],
    ["Centre", m.centre],
    ["Date", m.date],
    ["Made", m.madeAt],
  ];
  let y = 736;
  for (const [label, value] of lines) {
    page.drawText(label, { x: LEFT, y, size: 9, font, color: grey });
    page.drawText(safe(value), { x: LEFT + 70, y, size: 10, font: bold, maxWidth: 330, color: ink });
    y -= 14;
  }
  drawQr(page, m.number, RIGHT - 96, 722, 96);
  page.drawText(`Page ${pageNo} of ${pages}`, { x: RIGHT - 96, y: 708, size: 8, font, color: grey });
  // Column headings.
  const heading = TOP_ROWS + 10;
  page.drawText("Index number", { x: LEFT, y: heading, size: 9, font: bold, color: grey });
  page.drawText("Name", { x: LEFT + 110, y: heading, size: 9, font: bold, color: grey });
  page.drawText("Attendance", { x: LEFT + 290, y: heading, size: 9, font: bold, color: grey });
  page.drawText("Sheets", { x: LEFT + 370, y: heading, size: 9, font: bold, color: grey });
  page.drawLine({ start: { x: LEFT, y: heading - 5 }, end: { x: RIGHT, y: heading - 5 }, thickness: 0.7, color: grey });
}

/**
 * The collection manifest of one centre as an A4 PDF: the candidates in index-number order with attendance and the
 * sheets counted, the manifest number as text and as a QR code on every page, totals, and a signature box. Names are
 * on it because it is an internal staff document.
 */
export async function buildManifestPdf(m: ManifestData): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);

  const perPage = Math.floor((TOP_ROWS - BOTTOM) / ROW);
  const rowPages = Math.max(1, Math.ceil(m.rows.length / perPage));
  const lastUsed = m.rows.length - (rowPages - 1) * perPage;
  // The totals and signature box need room under the last row; if it does not fit, they take a page of their own.
  const fits = TOP_ROWS - lastUsed * ROW - 12 - BOTTOM >= SIGNATURE_HEIGHT;
  const pages = rowPages + (fits ? 0 : 1);

  const sitting = m.rows.filter((r) => r.attendance === "present" || r.attendance === "late");
  const absent = m.rows.filter((r) => r.attendance === "absent").length;
  const extra = sitting.reduce((n, r) => n + (r.extra_sheets ?? 0), 0);
  const uncounted = sitting.filter((r) => r.extra_sheets === null).length;

  let page: PDFPage = doc.addPage(A4);
  header(page, m, font, bold, 1, pages);
  let y = TOP_ROWS - 8;
  let onPage = 0;
  let pageNo = 1;
  for (const r of m.rows) {
    if (onPage === perPage) {
      pageNo += 1;
      page = doc.addPage(A4);
      header(page, m, font, bold, pageNo, pages);
      y = TOP_ROWS - 8;
      onPage = 0;
    }
    y -= ROW;
    page.drawText(safe(r.index_number ?? "-"), { x: LEFT, y: y + 4, size: 10, font, color: ink });
    page.drawText(safe(r.name), { x: LEFT + 110, y: y + 4, size: 10, font, maxWidth: 170, color: ink });
    page.drawText(ATTENDANCE[r.attendance] ?? "Not marked", { x: LEFT + 290, y: y + 4, size: 10, font, color: ink });
    page.drawText(sheetsText(r), { x: LEFT + 370, y: y + 4, size: 10, font, color: ink });
    onPage += 1;
  }

  if (!fits) {
    pageNo += 1;
    page = doc.addPage(A4);
    header(page, m, font, bold, pageNo, pages);
    y = TOP_ROWS - 8;
  }
  y -= 28;
  page.drawLine({ start: { x: LEFT, y: y + 14 }, end: { x: RIGHT, y: y + 14 }, thickness: 0.7, color: grey });
  const totals = [
    `Candidates listed: ${m.rows.length}`,
    `Sat the exam: ${sitting.length} (${sitting.length} booklets, ${extra} extra sheets${uncounted > 0 ? `, ${uncounted} not counted yet` : ""})`,
    `Absent: ${absent}`,
  ];
  for (const t of totals) {
    page.drawText(t, { x: LEFT, y, size: 10, font: bold, color: ink });
    y -= 15;
  }
  y -= 14;
  page.drawRectangle({ x: LEFT, y: y - 100, width: RIGHT - LEFT, height: 110, borderColor: ink, borderWidth: 1 });
  page.drawText("Collected by (name)", { x: LEFT + 10, y: y - 14, size: 9, font, color: grey });
  page.drawText("Signature", { x: LEFT + 10, y: y - 54, size: 9, font, color: grey });
  page.drawText("Date and time", { x: LEFT + 300, y: y - 54, size: 9, font, color: grey });
  page.drawLine({ start: { x: LEFT + 10, y: y - 40 }, end: { x: RIGHT - 10, y: y - 40 }, thickness: 0.5, color: grey });
  page.drawLine({ start: { x: LEFT + 10, y: y - 86 }, end: { x: LEFT + 280, y: y - 86 }, thickness: 0.5, color: grey });
  page.drawLine({ start: { x: LEFT + 300, y: y - 86 }, end: { x: RIGHT - 10, y: y - 86 }, thickness: 0.5, color: grey });

  return doc.save();
}
