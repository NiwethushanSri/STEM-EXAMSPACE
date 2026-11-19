import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { PDFDocument } from "pdf-lib";
import jsqrModule from "jsqr";
import {
  A4,
  BOTTOM_BAND,
  buildCopy,
  fitPage,
  inspectPaper,
  PaperError,
  qrMatrix,
  qrPayload,
  SIDE,
  TOP_BAND,
} from "./stamp.ts";

type JsQR = (
  d: Uint8ClampedArray,
  w: number,
  h: number,
) => { data: string } | null;
const jsQR = jsqrModule as unknown as JsQR;

const INFO = {
  candidateName: "Amara Perera",
  indexNumber: "SE-2027-0142",
  examCode: "MATHS-P1H",
  examDate: "5 Jun 2027",
  code: "7KQ2M9XDQ",
  sparePages: 2,
};

Deno.test("fit_a4_portrait_no_rotation", () => {
  const f = fitPage(A4.width, A4.height);
  assertEquals(f.rotate, 0);
  assert(f.scale <= 1 && f.scale > 0.8);
  assert(f.x >= SIDE - 1e-6);
  assert(f.y >= BOTTOM_BAND - 1e-6);
  assert(f.x + A4.width * f.scale <= A4.width - SIDE + 1e-6);
  assert(f.y + A4.height * f.scale <= A4.height - TOP_BAND + 1e-6);
});

Deno.test("fit_landscape_rotates", () => {
  const f = fitPage(842, 595);
  assertEquals(f.rotate, 90);
  assert(f.scale <= 1);
  // the turned page is 595 wide and 842 high
  assert(f.x + 595 * f.scale <= A4.width - SIDE + 1e-6);
  assert(f.y + 842 * f.scale <= A4.height - TOP_BAND + 1e-6);
  assert(f.y >= BOTTOM_BAND - 1e-6);
});

Deno.test("fit_a3_scales_down", () => {
  const f = fitPage(842, 1191);
  assertEquals(f.rotate, 0);
  assert(f.scale < 0.71);
  assert(f.y + 1191 * f.scale <= A4.height - TOP_BAND + 1e-6);
});

Deno.test("payload_format", () => {
  assertEquals(qrPayload("7KQ2M9XDQ", 3), "SX1.7KQ2M9XDQ.3");
});

async function master(): Promise<Uint8Array> {
  const d = await PDFDocument.create();
  d.addPage([595.28, 841.89]).drawText("A4 page");
  d.addPage([841.89, 595.28]).drawText("Landscape page");
  d.addPage([841.89, 1190.55]).drawText("A3 page");
  return await d.save();
}

Deno.test("copy_has_paper_plus_spare_pages_all_a4", async () => {
  const out = await buildCopy(await master(), INFO);
  const doc = await PDFDocument.load(out);
  assertEquals(doc.getPageCount(), 5);
  for (const p of doc.getPages()) {
    const { width, height } = p.getSize();
    assertEquals(Math.round(width * 100) / 100, 595.28);
    assertEquals(Math.round(height * 100) / 100, 841.89);
  }
});

Deno.test("qr_modules_decode", () => {
  const m = qrMatrix(qrPayload(INFO.code, 1));
  const px = 6, quiet = 4;
  const side = (m.size + quiet * 2) * px;
  const data = new Uint8ClampedArray(side * side * 4).fill(255);
  for (let r = 0; r < m.size; r++) {
    for (let c = 0; c < m.size; c++) {
      if (!m.get(r, c)) continue;
      for (let y = 0; y < px; y++) {
        for (let x = 0; x < px; x++) {
          const i = (((r + quiet) * px + y) * side + (c + quiet) * px + x) * 4;
          data[i] = data[i + 1] = data[i + 2] = 0;
        }
      }
    }
  }
  assertEquals(jsQR(data, side, side)?.data, "SX1.7KQ2M9XDQ.1");
});

Deno.test("encrypted_master_refused", async () => {
  const pdf = `%PDF-1.6
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] >>
endobj
4 0 obj
<< /Filter /Standard /V 1 /R 2 /O (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) /U (bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb) /P -4 >>
endobj
trailer
<< /Root 1 0 R /Size 5 /Encrypt 4 0 R >>
%%EOF
`;
  const err = await assertRejects(() =>
    inspectPaper(new TextEncoder().encode(pdf))
  );
  assert(err instanceof PaperError);
  assertEquals(err.reason, "encrypted");
});

Deno.test("garbage_unreadable_and_inspect_counts_pages", async () => {
  const err = await assertRejects(() =>
    inspectPaper(new Uint8Array([1, 2, 3]))
  );
  assertEquals((err as PaperError).reason, "unreadable");
  assertEquals((await inspectPaper(await master())).pageCount, 3);
});

Deno.test("timing_20_page_master", async () => {
  const d = await PDFDocument.create();
  for (let i = 0; i < 20; i++) {
    const p = d.addPage([595.28, 841.89]);
    for (let l = 0; l < 40; l++) {
      p.drawText(`Question ${i + 1} line ${l} lorem ipsum dolor sit amet`, {
        x: 50,
        y: 800 - l * 18,
      });
    }
  }
  const bytes = await d.save();
  const t0 = performance.now();
  const out = await buildCopy(bytes, INFO);
  const ms = performance.now() - t0;
  console.log(
    `TIMING buildCopy 20 pages + 2 spare: ${
      ms.toFixed(0)
    } ms, ${out.length} bytes`,
  );
  assertEquals((await PDFDocument.load(out)).getPageCount(), 22);
  assert(ms < 1000);
});
