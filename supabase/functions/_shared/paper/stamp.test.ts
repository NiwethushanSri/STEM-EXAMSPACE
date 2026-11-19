import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  decodePDFRawStream,
  PDFArray,
  PDFDict,
  PDFDocument,
  PDFName,
  type PDFNumber,
  type PDFRawStream,
  StandardFonts,
} from "pdf-lib";
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

Deno.test("name_keeps_printable_accents_transliterates_the_rest", async () => {
  const d = await PDFDocument.create();
  const bold = await d.embedFont(StandardFonts.HelveticaBold);
  // characters Helvetica (WinAnsi) can print stay as typed
  assertEquals(transliterate("José Müller", bold), "José Müller");
  assertEquals(
    transliterate("Renée Brontë Núñez François Ørsted Straße Æsa Œuvre", bold),
    "Renée Brontë Núñez François Ørsted Straße Æsa Œuvre",
  );
  // the same name typed with combining accents (NFD) is printed composed
  assertEquals(transliterate("José Müller", bold), "José Müller");
  // only what the font cannot encode is rewritten
  assertEquals(transliterate("Łukasz", bold), "Lukasz");
  assertEquals(transliterate("Łukasz Ørsted-Şahin", bold), "Lukasz Ørsted-Sahin");
  assertEquals(transliterate("Đorđe ı Ćosić", bold), "Dorde i Cosic");
  // the identity line prints the accents
  const font = await d.embedFont(StandardFonts.Helvetica);
  const line = identityLine(font, bold, { ...INFO, candidateName: "José Müller" });
  assertEquals(line.left, "José Müller · SE-2027-0142");
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

// ---------------------------------------------------------------------------
// Offset MediaBox and CropBox: reads the placed master page back out of the
// copy (its form BBox and Matrix, and the page's cm operators before Do) and
// maps master points onto the A4 sheet.
type M6 = [number, number, number, number, number, number];
const ID: M6 = [1, 0, 0, 1, 0, 0];
// p × a, then × b (PDF row-vector convention)
const mul = (a: M6, b: M6): M6 => [
  a[0] * b[0] + a[1] * b[2],
  a[0] * b[1] + a[1] * b[3],
  a[2] * b[0] + a[3] * b[2],
  a[2] * b[1] + a[3] * b[3],
  a[4] * b[0] + a[5] * b[2] + b[4],
  a[4] * b[1] + a[5] * b[3] + b[5],
];
const apply = (m: M6, x: number, y: number) => ({
  x: x * m[0] + y * m[2] + m[4],
  y: x * m[1] + y * m[3] + m[5],
});
const nums = (a: PDFArray) =>
  a.asArray().map((o) => (o as PDFNumber).asNumber());

async function placedMaster(copy: Uint8Array, pageIndex = 0) {
  const doc = await PDFDocument.load(copy);
  const page = doc.getPage(pageIndex);
  const contents = page.node.Contents();
  const streams = contents instanceof PDFArray
    ? contents.asArray().map((r) => doc.context.lookup(r) as PDFRawStream)
    : [contents as unknown as PDFRawStream];
  const text = streams.map((s) =>
    new TextDecoder().decode(decodePDFRawStream(s).decode())
  ).join("\n");
  let ctm = ID;
  const stack: M6[] = [];
  let operands: string[] = [];
  let drawn: { name: string; ctm: M6 } | null = null;
  for (const tok of text.split(/\s+/).filter(Boolean)) {
    if (/^[-+.\d]/.test(tok) || tok.startsWith("/")) {
      operands.push(tok);
      continue;
    }
    if (tok === "q") stack.push(ctm);
    else if (tok === "Q") ctm = stack.pop() ?? ID;
    else if (tok === "cm") ctm = mul(operands.slice(-6).map(Number) as M6, ctm);
    else if (tok === "Do") drawn = { name: operands.at(-1)!.slice(1), ctm };
    operands = [];
  }
  assert(drawn, "the master page is drawn on the sheet");
  const xobjects = page.node.Resources()!.lookup(PDFName.of("XObject"), PDFDict);
  const form = xobjects.lookup(PDFName.of(drawn.name)) as PDFRawStream;
  const bbox = nums(form.dict.lookup(PDFName.of("BBox"), PDFArray));
  const matrix = nums(form.dict.lookup(PDFName.of("Matrix"), PDFArray)) as M6;
  const toSheet = mul(matrix, drawn.ctm);
  const [l, b, r, t] = bbox;
  const corners = [[l, b], [r, b], [l, t], [r, t]].map(([x, y]) =>
    apply(toSheet, x, y)
  );
  const xs = corners.map((c) => c.x), ys = corners.map((c) => c.y);
  return {
    bbox,
    /** master point → sheet point, or null when the form BBox clips it away */
    place(x: number, y: number) {
      const inside = x >= l - 1e-6 && x <= r + 1e-6 && y >= b - 1e-6 &&
        y <= t + 1e-6;
      return inside ? apply(toSheet, x, y) : null;
    },
    footprint: {
      x: Math.min(...xs),
      y: Math.min(...ys),
      w: Math.max(...xs) - Math.min(...xs),
      h: Math.max(...ys) - Math.min(...ys),
    },
  };
}

function assertInsideContentArea(
  fp: { x: number; y: number; w: number; h: number },
) {
  assert(fp.x >= SIDE - 1e-6 && fp.x + fp.w <= A4.width - SIDE + 1e-6);
  assert(
    fp.y >= BOTTOM_BAND - 1e-6 && fp.y + fp.h <= A4.height - TOP_BAND + 1e-6,
  );
}

const near = (a: number, b: number) => Math.abs(a - b) < 1e-3;

Deno.test("offset_mediabox_placed_whole", async () => {
  // MediaBox [36 36 631 878]: an A4-sized page that does not start at 0,0
  const d = await PDFDocument.create();
  const p = d.addPage([595, 842]);
  p.setMediaBox(36, 36, 595, 842);
  // marks touching each corner of the box
  p.drawRectangle({ x: 36, y: 36, width: 4, height: 4 });
  p.drawRectangle({ x: 627, y: 874, width: 4, height: 4 });
  const copy = await buildCopy(await d.save(), { ...INFO, sparePages: 0 });
  const m = await placedMaster(copy);
  assertEquals(m.bbox, [36, 36, 631, 878]);
  const f = fitPage(595, 842);
  assert(near(m.footprint.x, f.x) && near(m.footprint.y, f.y));
  assert(near(m.footprint.w, 595 * f.scale) && near(m.footprint.h, 842 * f.scale));
  assertInsideContentArea(m.footprint);
  // content at the box edges is drawn, at the footprint's corners
  const ll = m.place(36, 36), ur = m.place(631, 878);
  assert(ll && ur, "corner content is inside the drawn area");
  assert(near(ll.x, f.x) && near(ll.y, f.y));
  assert(near(ur.x, f.x + 595 * f.scale) && near(ur.y, f.y + 842 * f.scale));
  // and nothing from outside the MediaBox (0..36) shows
  assertEquals(m.place(10, 10), null);
});

Deno.test("cropbox_smaller_than_mediabox_placed_without_slug", async () => {
  const d = await PDFDocument.create();
  const p = d.addPage([595, 842]);
  p.setCropBox(50, 60, 495, 722); // [50 60 545 782]
  p.drawRectangle({ x: 0, y: 0, width: 30, height: 30 }); // slug: crop marks
  p.drawRectangle({ x: 50, y: 60, width: 4, height: 4 });
  p.drawRectangle({ x: 541, y: 778, width: 4, height: 4 });
  const copy = await buildCopy(await d.save(), { ...INFO, sparePages: 0 });
  const m = await placedMaster(copy);
  assertEquals(m.bbox, [50, 60, 545, 782]);
  const f = fitPage(495, 722);
  assert(near(m.footprint.x, f.x) && near(m.footprint.y, f.y));
  assert(near(m.footprint.w, 495 * f.scale) && near(m.footprint.h, 722 * f.scale));
  assertInsideContentArea(m.footprint);
  const ll = m.place(50, 60), ur = m.place(545, 782);
  assert(ll && ur, "content at the crop edges is inside the drawn area");
  assert(near(ll.x, f.x) && near(ll.y, f.y));
  assert(near(ur.x, f.x + 495 * f.scale) && near(ur.y, f.y + 722 * f.scale));
  // the slug outside the CropBox is not printed
  assertEquals(m.place(10, 10), null);
});

Deno.test("offset_landscape_box_turned_inside_content_area", async () => {
  const d = await PDFDocument.create();
  const p = d.addPage([842, 595]);
  p.setMediaBox(-100, 200, 842, 595); // [-100 200 742 795], landscape
  p.drawRectangle({ x: -100, y: 200, width: 4, height: 4 });
  const copy = await buildCopy(await d.save(), { ...INFO, sparePages: 0 });
  const m = await placedMaster(copy);
  assertEquals(m.bbox, [-100, 200, 742, 795]);
  const f = fitPage(842, 595);
  assertEquals(f.rotate, 90);
  assert(near(m.footprint.w, 595 * f.scale) && near(m.footprint.h, 842 * f.scale));
  assertInsideContentArea(m.footprint);
  assert(m.place(-100, 200) && m.place(742, 795));
});

Deno.test("cropbox_outside_mediabox_falls_back_to_mediabox", async () => {
  const d = await PDFDocument.create();
  const p = d.addPage([595, 842]);
  p.setCropBox(1000, 1000, 50, 50);
  p.drawText("x");
  const copy = await buildCopy(await d.save(), { ...INFO, sparePages: 0 });
  assertEquals((await placedMaster(copy)).bbox, [0, 0, 595, 842]);
  assertEquals((await inspectPaper(await d.save())).pageCount, 1);
});

Deno.test("blank_master_page_without_contents_builds", async () => {
  const d = await PDFDocument.create();
  d.addPage([595, 842]); // no content stream at all
  d.addPage([595, 842]).drawText("Question 1");
  const out = await buildCopy(await d.save(), INFO);
  assertEquals((await PDFDocument.load(out)).getPageCount(), 4);
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
