import { inflateSync } from "node:zlib";
import { PDFDocument } from "pdf-lib";
import QRCode from "qrcode";
import { describe, expect, it } from "vitest";
import { buildManifestPdf, type ManifestData } from "@/lib/manifest-pdf";

function manifest(count: number, number = "M-MATHS-P1H-2027-06-01"): ManifestData {
  return {
    number,
    examTitle: "GCSE Maths Paper 1",
    examCode: "MATHS-P1H-2027-06",
    centre: "Main Hall, Room 1",
    date: "Sat 5 Jun 2027, 10:00",
    madeAt: "Sat 5 Jun 2027, 12:15",
    rows: Array.from({ length: count }, (_, i) => ({
      index_number: `SE-2027-${String(1000 + i)}`,
      name: `Candidate Number${i}`,
      attendance: i % 5 === 4 ? "absent" : "present",
      extra_sheets: i % 5 === 4 ? null : i % 3,
    })),
  };
}

/** All page content as text: every flate stream in the file, inflated. */
async function content(bytes: Uint8Array): Promise<string> {
  const raw = Buffer.from(bytes).toString("latin1");
  const out: string[] = [];
  for (const m of raw.matchAll(/stream\r?\n([\s\S]*?)\r?\nendstream/g)) {
    try {
      out.push(inflateSync(Buffer.from(m[1], "latin1")).toString("latin1"));
    } catch {
      /* not a flate stream (a font file) */
    }
  }
  return out.join("\n");
}
const hex = (s: string) => Buffer.from(s, "latin1").toString("hex").toUpperCase();

describe("collection manifest pdf", () => {
  it("manifest_pdf_has_qr_and_every_candidate", async () => {
    const m = manifest(70);
    const bytes = await buildManifestPdf(m);
    const doc = await PDFDocument.load(bytes);
    expect(doc.getPages().every((p) => Math.round(p.getWidth()) === 595 && Math.round(p.getHeight()) === 842)).toBe(true);
    expect(doc.getPageCount()).toBeGreaterThan(1);

    const text = await content(bytes);
    for (const r of m.rows) {
      expect(text).toContain(hex(r.index_number ?? ""));
      expect(text).toContain(hex(r.name));
    }
    expect(text).toContain(hex(m.number));

    // The QR code carries exactly the manifest number: one filled square per dark module.
    const dark = QRCode.create(m.number, { errorCorrectionLevel: "M" }).modules.data.filter(Boolean).length;
    const squares = text.match(/^0 0 0 rg$/gm)?.length ?? 0;
    expect(squares).toBe(dark * doc.getPageCount());
    const other = await content(await buildManifestPdf(manifest(70, "M-MATHS-P1H-2027-06-02")));
    expect(other).not.toBe(text);
  });

  it("manifest_pdf_shows_absent_without_sheets_and_a_signature_box", async () => {
    const text = await content(await buildManifestPdf(manifest(10)));
    expect(text).toContain(hex("Absent"));
    expect(text).toContain(hex("Booklet + 1 extra sheet"));
    expect(text).toContain(hex("Booklet + 2 extra sheets"));
    expect(text).toContain(hex("Signature"));
  });

  it("manifest_pdf_copes_with_no_candidates_and_odd_characters", async () => {
    const m = manifest(0);
    m.examTitle = "Maths 中文";
    const doc = await PDFDocument.load(await buildManifestPdf(m));
    expect(doc.getPageCount()).toBe(1);
  });
});
