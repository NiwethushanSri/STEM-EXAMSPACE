// Builds a personalised copy of a question paper: every master page sits on an
// A4 portrait sheet between a top band (identity) and a bottom band (page
// number, QR, readable code). Nothing in the master page is moved, cropped or
// covered. Pure module: no I/O, no personal data in errors.
import {
  degrees,
  PDFDocument,
  type PDFEmbeddedPage,
  type PDFFont,
  type PDFPage,
  rgb,
  StandardFonts,
} from "pdf-lib";
import QRCode from "qrcode";

export const A4 = { width: 595.28, height: 841.89 };
export const TOP_BAND = 34;
export const BOTTOM_BAND = 92;
export const SIDE = 18;

/** QR symbol (dark modules only, without quiet zone) is this wide, in points. */
export const QR_SIZE = 52;

export class PaperError extends Error {
  readonly reason: "encrypted" | "unreadable";
  constructor(reason: "encrypted" | "unreadable") {
    super(
      reason === "encrypted"
        ? "The paper is password protected."
        : "The paper could not be read.",
    );
    this.name = "PaperError";
    this.reason = reason;
  }
}

export interface CopyInfo {
  candidateName: string;
  indexNumber: string;
  examCode: string;
  examDate: string;
  code: string;
  sparePages: number;
}

/** Where a source page goes. width/height are the stored page size and
 * pageRotation its /Rotate entry (clockwise, as a viewer shows it). The page is
 * first made upright, then a landscape page is turned 90 degrees anticlockwise.
 * `angle` is the total anticlockwise turn; x,y is the lower-left corner of the
 * placed footprint; ox,oy is the origin to hand to drawPage. Scale never
 * exceeds 1. */
export function fitPage(
  width: number,
  height: number,
  pageRotation: number = 0,
): {
  rotate: 0 | 90;
  angle: 0 | 90 | 180 | 270;
  scale: number;
  x: number;
  y: number;
  ox: number;
  oy: number;
} {
  const r = (((Math.round(pageRotation / 90) * 90) % 360) + 360) % 360;
  const sideways = r === 90 || r === 270;
  const vw = sideways ? height : width;
  const vh = sideways ? width : height;
  const rotate: 0 | 90 = vw > vh ? 90 : 0;
  const angle = ((((360 - r + rotate) % 360) + 360) % 360) as
    | 0
    | 90
    | 180
    | 270;
  const turned = angle === 90 || angle === 270;
  const w = turned ? height : width;
  const h = turned ? width : height;
  const boxW = A4.width - 2 * SIDE;
  const boxH = A4.height - TOP_BAND - BOTTOM_BAND;
  const scale = Math.min(1, boxW / w, boxH / h);
  const x = SIDE + (boxW - w * scale) / 2;
  const y = BOTTOM_BAND + (boxH - h * scale) / 2;
  const sw = width * scale;
  const sh = height * scale;
  const ox = angle === 90 ? x + sh : angle === 180 ? x + sw : x;
  const oy = angle === 180 ? y + sh : angle === 270 ? y + sw : y;
  return { rotate, angle, scale, x, y, ox, oy };
}

/** Text under the QR occupies y from 0 to this height. */
export const CODE_TEXT_TOP = 18;

/** Nothing printed in either band may sit closer than this to a sheet edge. */
export const PRINT_MARGIN = 12;
/** Baselines (points from the bottom edge) of the bottom-band texts. */
export const CODE_TEXT_Y = 12;
export const PAGE_TEXT_Y = 30;
/** Baseline of the top-band texts, measured down from the top edge. */
export const TOP_TEXT_DROP = 26;
const TOP_TEXT_SIZE = 10;

/** Fits "name · index" on the left and "exam · date" on the right of one line:
 * shrinks the name text to 7 pt, then shortens only the name with an ellipsis. */
export function identityLine(font: PDFFont, bold: PDFFont, info: CopyInfo) {
  const right = safe(font, `${info.examCode} · ${info.examDate}`);
  const rightWidth = font.widthOfTextAtSize(right, TOP_TEXT_SIZE);
  const avail = A4.width - 2 * SIDE - rightWidth - 12;
  const suffix = ` · ${info.indexNumber}`;
  const name = transliterate(info.candidateName, bold).trim();
  const make = (n: string) => safe(bold, n + suffix);
  let size = TOP_TEXT_SIZE;
  let left = make(name);
  while (bold.widthOfTextAtSize(left, size) > avail && size > 7) size -= 0.5;
  if (bold.widthOfTextAtSize(left, size) > avail) {
    let n = name;
    while (
      n.length > 0 && bold.widthOfTextAtSize(make(n + "…"), size) > avail
    ) {
      n = n.slice(0, -1).trimEnd();
    }
    left = make(n.length > 0 ? n + "…" : "");
    if (n.length === 0) left = safe(bold, `${suffix}`.replace(/^ · /, ""));
  }
  return {
    left,
    leftSize: size,
    leftWidth: bold.widthOfTextAtSize(left, size),
    right,
    rightSize: TOP_TEXT_SIZE,
    rightWidth,
  };
}

/** Lower-left of the QR symbol; the 4-module quiet zone around it lies wholly
 * inside the bottom band, right of the margin and above the code text. */
export function qrLayout(
  modules: number,
): { x: number; y: number; quiet: number } {
  const quiet = (QR_SIZE / modules) * 4;
  return {
    x: A4.width - SIDE - quiet - QR_SIZE,
    y: CODE_TEXT_TOP + quiet,
    quiet,
  };
}

export function qrPayload(code: string, page: number): string {
  return `SX1.${code}.${page}`;
}

export function qrMatrix(
  payload: string,
): { size: number; get: (row: number, col: number) => boolean } {
  const qr = QRCode.create(payload, { errorCorrectionLevel: "M" });
  return { size: qr.modules.size, get: (r, c) => !!qr.modules.get(r, c) };
}

/** The part of a page a viewer shows: the CropBox clipped to the MediaBox,
 * or the MediaBox when there is no usable CropBox. Corners are kept as stored
 * (a box need not start at 0,0) and put in order if written the other way. */
export function visibleBox(
  page: PDFPage,
): { left: number; bottom: number; right: number; top: number } {
  const norm = (r: { x: number; y: number; width: number; height: number }) => ({
    left: Math.min(r.x, r.x + r.width),
    bottom: Math.min(r.y, r.y + r.height),
    right: Math.max(r.x, r.x + r.width),
    top: Math.max(r.y, r.y + r.height),
  });
  const media = norm(page.getMediaBox());
  let crop = media;
  try {
    crop = norm(page.getCropBox());
  } catch {
    // a malformed CropBox is ignored: the MediaBox is what the page is
  }
  const box = {
    left: Math.max(media.left, crop.left),
    bottom: Math.max(media.bottom, crop.bottom),
    right: Math.min(media.right, crop.right),
    top: Math.min(media.top, crop.top),
  };
  return box.right > box.left && box.top > box.bottom ? box : media;
}

export async function inspectPaper(
  bytes: Uint8Array,
): Promise<{ pageCount: number }> {
  let doc: PDFDocument;
  try {
    doc = await PDFDocument.load(bytes);
  } catch (e) {
    if (isEncrypted(e)) throw new PaperError("encrypted");
    throw new PaperError("unreadable");
  }
  const pageCount = doc.getPageCount();
  if (pageCount < 1) throw new PaperError("unreadable");
  for (const p of doc.getPages()) {
    let width: number, height: number;
    try {
      const b = visibleBox(p);
      width = b.right - b.left;
      height = b.top - b.bottom;
    } catch {
      throw new PaperError("unreadable");
    }
    if (!(width > 0 && height > 0) || !isFinite(width) || !isFinite(height)) {
      throw new PaperError("unreadable");
    }
  }
  return { pageCount };
}

function readable(code: string, page: number): string {
  return `${code.slice(0, 4)}-${code.slice(4, 8)}-${code.slice(8)} · p${
    String(page).padStart(2, "0")
  }`;
}

const SPECIAL: Record<string, string> = {
  "Ł": "L",
  "ł": "l",
  "Ø": "O",
  "ø": "o",
  "ß": "ss",
  "Æ": "AE",
  "æ": "ae",
  "Œ": "OE",
  "œ": "oe",
  "Đ": "D",
  "đ": "d",
  "ı": "i",
};

/** Keeps every character the font can print (é, ü, ñ, ç, ß, Ø … in standard
 * Helvetica's WinAnsi set) and only rewrites the others: Ł → L, Ş → S. What
 * still cannot be printed is left for safe() to replace. */
export function transliterate(text: string, font: PDFFont): string {
  const ok = new Set(font.getCharacterSet());
  const prints = (ch: string) => ok.has(ch.codePointAt(0)!);
  let t = "";
  for (const ch of text.normalize("NFC")) {
    if (prints(ch)) t += ch;
    else if (SPECIAL[ch] !== undefined) t += SPECIAL[ch];
    else {
      for (const part of ch.normalize("NFKD").replace(/\p{M}/gu, "")) t += part;
    }
  }
  return t;
}

function safe(font: PDFFont, text: string): string {
  const ok = new Set(font.getCharacterSet());
  let out = "";
  for (const ch of text) out += ok.has(ch.codePointAt(0)!) ? ch : "?";
  return out;
}

const INK = rgb(0.1, 0.1, 0.1);

function drawQr(page: PDFPage, payload: string, right: number, bottom: number) {
  const m = qrMatrix(payload);
  const mod = QR_SIZE / m.size;
  let d = "";
  for (let r = 0; r < m.size; r++) {
    let c = 0;
    while (c < m.size) {
      if (!m.get(r, c)) {
        c++;
        continue;
      }
      const start = c;
      while (c < m.size && m.get(r, c)) c++;
      d += `M${start} ${r}h${c - start}v1h-${c - start}z`;
    }
  }
  page.drawSvgPath(d, {
    x: right - QR_SIZE,
    y: bottom + QR_SIZE,
    scale: mod,
    color: rgb(0, 0, 0),
    borderWidth: 0,
  });
}

function drawBands(
  page: PDFPage,
  font: PDFFont,
  bold: PDFFont,
  info: CopyInfo,
  n: number,
  total: number,
) {
  const { width: W, height: H } = A4;
  // top band
  const id = identityLine(font, bold, info);
  const ty = H - TOP_TEXT_DROP;
  page.drawText(id.left, {
    x: SIDE,
    y: ty,
    size: id.leftSize,
    font: bold,
    color: INK,
  });
  page.drawText(id.right, {
    x: W - SIDE - id.rightWidth,
    y: ty,
    size: id.rightSize,
    font,
    color: INK,
  });
  page.drawLine({
    start: { x: SIDE, y: H - TOP_BAND + 4 },
    end: { x: W - SIDE, y: H - TOP_BAND + 4 },
    thickness: 0.5,
    color: INK,
  });
  // bottom band
  page.drawLine({
    start: { x: SIDE, y: BOTTOM_BAND - 0.5 },
    end: { x: W - SIDE, y: BOTTOM_BAND - 0.5 },
    thickness: 0.5,
    color: INK,
  });
  page.drawText(`Page ${n} of ${total}`, {
    x: SIDE,
    y: PAGE_TEXT_Y,
    size: 10,
    font,
    color: INK,
  });
  // QR sits right of the band with a 4-module quiet zone to its right
  const lay = qrLayout(qrMatrix(qrPayload(info.code, n)).size);
  const qrRight = lay.x + QR_SIZE;
  drawQr(page, qrPayload(info.code, n), qrRight, lay.y);
  const label = readable(info.code, n);
  const lw = font.widthOfTextAtSize(label, 7);
  page.drawText(label, {
    x: qrRight - QR_SIZE / 2 - lw / 2,
    y: CODE_TEXT_Y,
    size: 7,
    font,
    color: INK,
  });
}

function drawSpare(page: PDFPage, font: PDFFont, bold: PDFFont) {
  const top = A4.height - TOP_BAND - 14;
  page.drawText("Additional answer page", {
    x: SIDE,
    y: top - 12,
    size: 14,
    font: bold,
    color: INK,
  });
  const bw = 150;
  page.drawText("Question number", {
    x: A4.width - SIDE - bw,
    y: top - 10,
    size: 8,
    font,
    color: INK,
  });
  page.drawRectangle({
    x: A4.width - SIDE - bw,
    y: top - 38,
    width: bw,
    height: 24,
    borderWidth: 0.75,
    borderColor: INK,
  });
  for (let y = top - 62; y > BOTTOM_BAND + 12; y -= 24) {
    page.drawLine({
      start: { x: SIDE, y },
      end: { x: A4.width - SIDE, y },
      thickness: 0.4,
      color: rgb(0.6, 0.6, 0.6),
    });
  }
}

export async function buildCopy(
  master: Uint8Array,
  info: CopyInfo,
): Promise<Uint8Array> {
  let src: PDFDocument;
  try {
    src = await PDFDocument.load(master);
  } catch (e) {
    if (isEncrypted(e)) throw new PaperError("encrypted");
    throw new PaperError("unreadable");
  }
  const srcPages = src.getPages();
  if (srcPages.length < 1) throw new PaperError("unreadable");
  const out = await PDFDocument.create();
  const font = await out.embedFont(StandardFonts.Helvetica);
  const bold = await out.embedFont(StandardFonts.HelveticaBold);
  // Each page is embedded by the box a viewer shows (its CropBox, else its
  // MediaBox, at its own origin), so an offset MediaBox or a CropBox is neither
  // cut off nor padded with what lies outside it.
  let boxes: ReturnType<typeof visibleBox>[];
  try {
    boxes = srcPages.map(visibleBox);
  } catch {
    throw new PaperError("unreadable");
  }
  // A truly blank page may have no content stream, which pdf-lib cannot embed.
  for (const p of srcPages) {
    if (!p.node.Contents()) {
      p.node.addContentStream(src.context.register(src.context.contentStream([])));
    }
  }
  const embedded: PDFEmbeddedPage[] = await out.embedPages(srcPages, boxes);
  const total = srcPages.length + info.sparePages;

  embedded.forEach((ep, i) => {
    const page = out.addPage([A4.width, A4.height]);
    const b = boxes[i];
    const f = fitPage(
      b.right - b.left,
      b.top - b.bottom,
      srcPages[i].getRotation().angle,
    );
    page.drawPage(ep, {
      x: f.ox,
      y: f.oy,
      xScale: f.scale,
      yScale: f.scale,
      rotate: degrees(f.angle),
    });
    drawBands(page, font, bold, info, i + 1, total);
  });
  for (let s = 0; s < info.sparePages; s++) {
    const page = out.addPage([A4.width, A4.height]);
    drawSpare(page, font, bold);
    drawBands(page, font, bold, info, srcPages.length + s + 1, total);
  }
  return await out.save();
}

// pdf-lib's EncryptedPDFError is not exported, so recognise it by its message.
function isEncrypted(e: unknown): boolean {
  return e instanceof Error && /is encrypted/i.test(e.message);
}
