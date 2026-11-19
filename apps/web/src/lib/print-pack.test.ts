import { PDFDocument } from "pdf-lib";
import { describe, expect, it } from "vitest";
import { buildPrintPack, fetchInOrder, missingPaperWarning } from "@/lib/print-pack";

async function onePage(): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  doc.addPage([595, 842]);
  return doc.save();
}

const cover = {
  examTitle: "GCSE Maths",
  examCode: "MATHS-P1H-2027-06",
  centre: "Main Hall",
  room: "Room 1",
  date: "Sat 5 Jun 2027, 10:00",
  candidates: 3,
  paperVersion: 2,
  madeAt: "Fri 4 Jun 2027, 16:00",
};

describe("print pack", () => {
  it("print_pack_cover_then_copies_in_order", async () => {
    const copies = await Promise.all([onePage(), onePage(), onePage()]);
    const out = await PDFDocument.load(await buildPrintPack(copies, cover));
    expect(out.getPageCount()).toBe(4);
  });

  it("fetchInOrder keeps order, never exceeds 3 in flight and reports progress", async () => {
    let live = 0;
    let peak = 0;
    const seen: number[] = [];
    const out = await fetchInOrder(
      ["a", "b", "c", "d", "e", "f", "g"],
      async (c, i) => {
        live++;
        peak = Math.max(peak, live);
        await new Promise((r) => setTimeout(r, 5 * (7 - i)));
        live--;
        return { ok: true as const, value: c.toUpperCase() };
      },
      { limit: 3, onProgress: (n) => seen.push(n) },
    );
    expect(out).toEqual({ ok: true, values: ["A", "B", "C", "D", "E", "F", "G"] });
    expect(peak).toBeLessThanOrEqual(3);
    expect(seen[seen.length - 1]).toBe(7);
  });

  it("fetchInOrder stops and names the candidate that failed", async () => {
    let started = 0;
    const out = await fetchInOrder(
      ["a", "b", "c", "d", "e", "f"],
      async (c, i) => {
        started++;
        await new Promise((r) => setTimeout(r, 2));
        return i === 1 ? { ok: false as const } : { ok: true as const, value: c };
      },
      { limit: 2 },
    );
    expect(out).toEqual({ ok: false, failedIndex: 1 });
    expect(started).toBeLessThan(6);
  });
});

describe("missing paper warning", () => {
  const now = new Date("2027-06-04T12:00:00Z");
  const at = (h: number) => new Date(now.getTime() + h * 3600_000).toISOString();

  it("missing_paper_warning_window", () => {
    expect(missingPaperWarning({ status: "published", hasPaper: false, releaseAt: at(25) }, now)).toBe(false);
    expect(missingPaperWarning({ status: "published", hasPaper: false, releaseAt: at(23) }, now)).toBe(true);
    expect(missingPaperWarning({ status: "published", hasPaper: true, releaseAt: at(23) }, now)).toBe(false);
    expect(missingPaperWarning({ status: "draft", hasPaper: false, releaseAt: at(23) }, now)).toBe(false);
    expect(missingPaperWarning({ status: "published", hasPaper: false, releaseAt: at(-2) }, now)).toBe(true);
  });
});
