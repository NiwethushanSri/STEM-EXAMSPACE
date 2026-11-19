import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { PDFDocument, StandardFonts } from "pdf-lib";
import jsqrModule from "jsqr";
import {
  A4,
  BOTTOM_BAND,
  buildCopy,
  CODE_TEXT_TOP,
  CODE_TEXT_Y,
  fitPage,
  identityLine,
  inspectPaper,
  PAGE_TEXT_Y,
  PaperError,
  PRINT_MARGIN,
  QR_SIZE,
  qrLayout,
  qrMatrix,
  qrPayload,
  SIDE,
  TOP_BAND,
  TOP_TEXT_DROP,
  transliterate,
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

Deno.test("qr_quiet_zone_inside_band", () => {
  const size = qrMatrix(qrPayload(INFO.code, 1)).size;
  const l = qrLayout(size);
  assertEquals(Math.round(QR_SIZE), 52);
  assert(Math.abs(l.quiet - (QR_SIZE / size) * 4) < 1e-9);
  assert(l.x - l.quiet >= SIDE - 1e-6);
  assert(l.x + QR_SIZE + l.quiet <= A4.width - SIDE + 1e-6);
  assert(l.y - l.quiet >= CODE_TEXT_TOP - 1e-6);
  assert(l.y + QR_SIZE + l.quiet <= BOTTOM_BAND - 1e-6);
  // also with a three-digit page number
  const big = qrLayout(qrMatrix(qrPayload(INFO.code, 123)).size);
  assert(big.y + QR_SIZE + big.quiet <= BOTTOM_BAND - 1e-6);
});

Deno.test("name_transliterated_to_winansi", () => {
  assertEquals(transliterate("Łukasz Ørsted-Şahin"), "Lukasz Orsted-Sahin");
  assertEquals(
    transliterate("Straße Æther Œuvre Đorđe ı"),
    "Strasse AEther OEuvre Dorde i",
  );
});

Deno.test("copy_builds_with_non_winansi_name", async () => {
  const out = await buildCopy(await master(), {
    ...INFO,
    candidateName: "Łukasz Ørsted-Şahin 王",
  });
  assertEquals((await PDFDocument.load(out)).getPageCount(), 5);
});

Deno.test("fit_honours_page_rotate", () => {
  // portrait page stored as landscape plus /Rotate 90 or 270: upright portrait
  const ref = fitPage(595.28, 841.89);
  for (const rot of [90, 270]) {
    const f = fitPage(841.89, 595.28, rot);
    assertEquals(f.rotate, 0);
    assertEquals(f.angle, rot === 90 ? 270 : 90);
    assert(Math.abs(f.scale - ref.scale) < 1e-9);
    assert(Math.abs(f.x - ref.x) < 1e-6 && Math.abs(f.y - ref.y) < 1e-6);
  }
  // origin: angle 270 draws from the top-left of the footprint, 90 from bottom-right
  const f270 = fitPage(841.89, 595.28, 90);
  assert(Math.abs(f270.oy - (f270.y + 841.89 * f270.scale)) < 1e-6);
  assert(Math.abs(f270.ox - f270.x) < 1e-6);
  const f90 = fitPage(841.89, 595.28, 270);
  assert(Math.abs(f90.ox - (f90.x + 595.28 * f90.scale)) < 1e-6);
  // landscape visible via /Rotate 90 on a portrait-stored page: turned to fit
  const l = fitPage(595.28, 841.89, 90);
  assertEquals(l.rotate, 90);
  assertEquals(l.angle, 0);
  // upside-down portrait
  assertEquals(fitPage(595.28, 841.89, 180).angle, 180);
});

Deno.test("copy_with_rotated_pages_all_a4", async () => {
  const d = await PDFDocument.create();
  const a = d.addPage([841.89, 595.28]);
  a.drawText("a");
  a.setRotation({ type: "degrees", angle: 90 } as never);
  const b = d.addPage([841.89, 595.28]);
  b.drawText("b");
  b.setRotation({ type: "degrees", angle: 270 } as never);
  const out = await buildCopy(await d.save(), INFO);
  assertEquals((await PDFDocument.load(out)).getPageCount(), 4);
});

Deno.test("band_elements_clear_of_sheet_edges", () => {
  const M = PRINT_MARGIN;
  assert(M >= 12);
  assert(SIDE >= M);
  assert(CODE_TEXT_Y >= M);
  assert(PAGE_TEXT_Y >= M);
  assert(TOP_TEXT_DROP - 10 >= M); // cap height of 10 pt text below the top edge
  for (const n of [21, 25, 29]) {
    const l = qrLayout(n);
    assert(l.x - l.quiet >= M && l.x + QR_SIZE + l.quiet <= A4.width - M);
    assert(l.y - l.quiet >= M);
    assert(l.y + QR_SIZE + l.quiet <= BOTTOM_BAND);
  }
  assert(CODE_TEXT_TOP >= CODE_TEXT_Y + 5);
});

Deno.test("long_name_shrinks_then_truncates_index_intact", async () => {
  const d = await PDFDocument.create();
  const font = await d.embedFont(StandardFonts.Helvetica);
  const bold = await d.embedFont(StandardFonts.HelveticaBold);
  const limit = A4.width - 2 * SIDE;
  const short = identityLine(font, bold, INFO);
  assertEquals(short.leftSize, 10);
  assertEquals(short.left, "Amara Perera \u00b7 SE-2027-0142");
  const mid = identityLine(font, bold, {
    ...INFO,
    candidateName:
      "Maria Fernanda Gonzalez-Hernandez de la Cruz y Alvarez-Castellanos Montenegro Villanueva Rodriguez",
  });
  assert(mid.leftSize < 10 && mid.leftSize >= 7);
  const long = identityLine(font, bold, {
    ...INFO,
    candidateName: "Abcdefghij ".repeat(12),
  });
  for (const r of [mid, long]) {
    assert(r.leftWidth + 12 + r.rightWidth <= limit + 1e-6);
    assert(r.left.endsWith("\u00b7 SE-2027-0142"));
  }
  assertEquals(long.leftSize, 7);
  assert(long.left.includes("\u2026"));
  const out = await buildCopy(await master(), {
    ...INFO,
    candidateName: "Abcdefghij ".repeat(12),
  });
  assertEquals((await PDFDocument.load(out)).getPageCount(), 5);
});

Deno.test("fit_contained_for_all_rotations_and_sizes", () => {
  const boxW = A4.width - 2 * SIDE;
  for (
    const [w, h] of [[595.28, 841.89], [841.89, 595.28], [841.89, 1190.55], [
      300,
      400,
    ], [1200, 500]]
  ) {
    for (const rot of [0, 90, 180, 270]) {
      const f = fitPage(w, h, rot);
      const turned = f.angle === 90 || f.angle === 270;
      const fw = (turned ? h : w) * f.scale;
      const fh = (turned ? w : h) * f.scale;
      assert(f.scale <= 1);
      assert(f.x >= SIDE - 1e-6 && f.x + fw <= A4.width - SIDE + 1e-6);
      assert(
        f.y >= BOTTOM_BAND - 1e-6 && f.y + fh <= A4.height - TOP_BAND + 1e-6,
      );
      assert(boxW > 0);
    }
  }
});
