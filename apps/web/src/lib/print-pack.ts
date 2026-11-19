import { PDFDocument, StandardFonts, rgb } from "pdf-lib";

export type PackCover = {
  examTitle: string;
  examCode: string;
  centre: string;
  room: string;
  date: string;
  candidates: number;
  paperVersion: number;
  madeAt: string;
};

/** The standard PDF fonts only draw Latin-1; anything else (an exam named in another script) shows as "?". */
const safe = (s: string) => s.replace(/[^ -~ -ÿ]/g, "?");

/** One PDF for a centre: a cover page, then every candidate's copy in the order given. */
export async function buildPrintPack(copies: Uint8Array[], cover: PackCover): Promise<Uint8Array> {
  const out = await PDFDocument.create();
  const font = await out.embedFont(StandardFonts.Helvetica);
  const bold = await out.embedFont(StandardFonts.HelveticaBold);
  const page = out.addPage([595.28, 841.89]);
  const left = 56;
  page.drawText(safe(cover.examTitle), { x: left, y: 760, size: 22, font: bold, maxWidth: 480, color: rgb(0.1, 0.1, 0.1) });
  page.drawText("Centre print pack", { x: left, y: 730, size: 12, font, color: rgb(0.35, 0.35, 0.35) });
  const rows: [string, string][] = [
    ["Exam code", cover.examCode],
    ["Centre", cover.centre],
    ["Room", cover.room],
    ["Date", cover.date],
    ["Candidates", String(cover.candidates)],
    ["Paper version", String(cover.paperVersion)],
    ["Pack made", cover.madeAt],
  ];
  let y = 680;
  for (const [label, value] of rows) {
    page.drawText(label, { x: left, y, size: 11, font, color: rgb(0.35, 0.35, 0.35) });
    page.drawText(safe(value), { x: left + 130, y, size: 13, font: bold, maxWidth: 350, color: rgb(0.1, 0.1, 0.1) });
    y -= 30;
  }
  for (const bytes of copies) {
    const src = await PDFDocument.load(bytes);
    const pages = await out.copyPages(src, src.getPageIndices());
    for (const p of pages) out.addPage(p);
  }
  return out.save();
}

/** True when an exam is published, has no question paper, and its release time is less than 24 hours away (or past). */
export function missingPaperWarning(exam: { status: string; hasPaper: boolean; releaseAt: string }, now: Date): boolean {
  if (exam.status !== "published" || exam.hasPaper) return false;
  const release = Date.parse(exam.releaseAt);
  if (Number.isNaN(release)) return false;
  return release - now.getTime() <= 24 * 3600_000;
}

export type FetchOutcome<T> = { ok: true; value: T } | { ok: false };

/**
 * Runs `fetchOne` over the items with at most `limit` in flight, keeping the results in the items' order.
 * The first failure stops anything new from starting and is reported by its position, so a pack is never
 * built from a partial set.
 */
export async function fetchInOrder<I, T>(
  items: readonly I[],
  fetchOne: (item: I, index: number) => Promise<FetchOutcome<T>>,
  opts: { limit?: number; onProgress?: (done: number) => void } = {},
): Promise<{ ok: true; values: T[] } | { ok: false; failedIndex: number }> {
  const limit = Math.max(1, opts.limit ?? 3);
  const values: T[] = new Array(items.length);
  let next = 0;
  let done = 0;
  let failed: number | null = null;
  async function worker() {
    while (failed === null && next < items.length) {
      const i = next++;
      let res: FetchOutcome<T>;
      try {
        res = await fetchOne(items[i], i);
      } catch {
        res = { ok: false };
      }
      if (!res.ok) {
        failed = failed === null ? i : Math.min(failed, i);
        return;
      }
      values[i] = res.value;
      opts.onProgress?.(++done);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return failed === null ? { ok: true, values } : { ok: false, failedIndex: failed };
}
