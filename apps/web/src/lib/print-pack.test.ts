import { PDFDocument } from "pdf-lib";
import { describe, expect, it } from "vitest";
import { buildPrintPack, fetchInOrder, missingPaperWarning, type FetchOutcome } from "@/lib/print-pack";

async function onePage(width = 595): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  doc.addPage([width, 842]);
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
    const copies = await Promise.all([onePage(300), onePage(400), onePage(500)]);
    const out = await PDFDocument.load(await buildPrintPack(copies, cover));
    expect(out.getPageCount()).toBe(4);
    // The cover is A4 wide; the copies follow in the order given (told apart by width).
    expect(out.getPages().map((p) => Math.round(p.getWidth()))).toEqual([595, 300, 400, 500]);
  });

  it("fetchInOrder hands results over in order, once each, holding at most the in-flight limit", async () => {
    let live = 0;
    let peak = 0;
    let held = 0;
    const got: string[] = [];
    const progress: number[] = [];
    const out = await fetchInOrder(
      ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"],
      async (c, i) => {
        live++;
        peak = Math.max(peak, live);
        await new Promise((r) => setTimeout(r, i === 0 ? 40 : 3)); // the first is slow, the rest race ahead
        live--;
        return { ok: true as const, value: c.toUpperCase() };
      },
      (v) => {
        got.push(v);
      },
      { limit: 3, onProgress: (n) => progress.push(n), onBuffered: (n) => (held = Math.max(held, n)) },
    );
    expect(out).toEqual({ ok: true });
    expect(got).toEqual(["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"]);
    expect(peak).toBeLessThanOrEqual(3);
    expect(held).toBeLessThanOrEqual(3);
    expect(progress[progress.length - 1]).toBe(10);
  });

  it("fetchInOrder stops and names the candidate that failed", async () => {
    let started = 0;
    const got: string[] = [];
    const out = await fetchInOrder(
      ["a", "b", "c", "d", "e", "f"],
      async (c, i): Promise<FetchOutcome<string>> => {
        started++;
        await new Promise((r) => setTimeout(r, 2));
        return i === 1 ? { ok: false as const } : { ok: true as const, value: c };
      },
      (v) => {
        got.push(v);
      },
      { limit: 2 },
    );
    expect(out).toEqual({ ok: false, failedIndex: 1 });
    expect(started).toBeLessThan(6);
    expect(got).toEqual(["a"]);
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
