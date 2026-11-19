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

export type PackBuilder = {
  /** Adds one copy's pages after those already added. The caller can drop its bytes straight away. */
  append(bytes: Uint8Array): Promise<void>;
  finish(): Promise<Uint8Array>;
};

/** Starts a centre pack with its cover page; copies are merged one at a time with `append`, so they never all sit in memory. */
export async function createPackBuilder(cover: PackCover): Promise<PackBuilder> {
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
  return {
    async append(bytes) {
      const src = await PDFDocument.load(bytes);
      const pages = await out.copyPages(src, src.getPageIndices());
      for (const p of pages) out.addPage(p);
    },
    finish: () => out.save(),
  };
}

/** One PDF for a centre: a cover page, then every candidate copy in the order given. */
export async function buildPrintPack(copies: Uint8Array[], cover: PackCover): Promise<Uint8Array> {
  const builder = await createPackBuilder(cover);
  for (const bytes of copies) await builder.append(bytes);
  return builder.finish();
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
 * Fetches the items with at most `limit` in flight and hands each result to `consume` strictly in the order of
 * the items, then forgets it. A fetch never starts more than `limit` places ahead of the next item to consume,
 * so at most `limit` results are ever held. The first failure (a fetch or a consume) stops new work and is
 * reported by its position, so a pack is never built from a partial set.
 */
export async function fetchInOrder<I, T>(
  items: readonly I[],
  fetchOne: (item: I, index: number) => Promise<FetchOutcome<T>>,
  consume: (value: T, index: number) => Promise<void> | void,
  opts: { limit?: number; onProgress?: (done: number) => void; onBuffered?: (held: number) => void } = {},
): Promise<{ ok: true } | { ok: false; failedIndex: number }> {
  const limit = Math.max(1, opts.limit ?? 3);
  const held = new Map<number, T>();
  let next = 0;
  let consumed = 0;
  let draining = false;
  let failed: number | null = null;
  const waiting: (() => void)[] = [];
  const wake = () => waiting.splice(0).forEach((f) => f());
  const fail = (i: number) => {
    failed = failed === null ? i : Math.min(failed, i);
    wake();
  };

  async function drain() {
    if (draining) return;
    draining = true;
    try {
      while (failed === null && held.has(consumed)) {
        const value = held.get(consumed) as T;
        held.delete(consumed);
        try {
          await consume(value, consumed);
        } catch {
          fail(consumed);
          return;
        }
        consumed++;
        opts.onProgress?.(consumed);
        wake();
      }
    } finally {
      draining = false;
    }
  }

  async function worker() {
    while (failed === null && next < items.length) {
      if (next - consumed >= limit) {
        await new Promise<void>((r) => waiting.push(r));
        continue;
      }
      const i = next++;
      let res: FetchOutcome<T>;
      try {
        res = await fetchOne(items[i], i);
      } catch {
        res = { ok: false };
      }
      if (!res.ok) return fail(i);
      held.set(i, res.value);
      opts.onBuffered?.(held.size);
      await drain();
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return failed === null ? { ok: true } : { ok: false, failedIndex: failed };
}
