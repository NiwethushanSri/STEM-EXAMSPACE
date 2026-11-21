// Writes the PDF fixtures the Python processor tests use.
// Run from the repository root: deno run -A --config supabase/functions/deno.json scripts/make-script-fixtures.ts
import { PDFDocument } from "pdf-lib";
import { buildCopy } from "../supabase/functions/_shared/paper/stamp.ts";
import { makePdf } from "../supabase/functions/_shared/paper/test_fixtures.ts";

const OUT = new URL("../services/processor/tests/fixtures/", import.meta.url);

// Copy codes follow the 1A rule: 8 characters of the base-32 alphabet read as a
// number, then check character = CHECK[value % 37] (public.copy_code_valid).
const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const CHECK = ALPHABET + "*~$=U";

function makeCode(body: string): string {
  let value = 0;
  for (const ch of body) value = value * 32 + ALPHABET.indexOf(ch);
  return body + CHECK[value % 37];
}

const CODE_A = makeCode("A7K2M9QX");
const CODE_B = makeCode("B3N8R5TW");

async function makeLandscape(): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  doc.addPage([842, 595]).drawText("Landscape question page", { x: 60, y: 500 });
  return await doc.save();
}

const portrait = await makePdf(3);
const landscape = await makeLandscape();
const base = { examCode: "ZZFIXTURE", examDate: "2026-12-01" };

const files: Record<string, Uint8Array> = {
  "copy-a.pdf": await buildCopy(portrait, {
    ...base, candidateName: "Alex Example", indexNumber: "ZZ-0001", code: CODE_A, sparePages: 2,
  }),
  "copy-b.pdf": await buildCopy(portrait, {
    ...base, candidateName: "Blake Sample", indexNumber: "ZZ-0002", code: CODE_B, sparePages: 2,
  }),
  "copy-landscape.pdf": await buildCopy(landscape, {
    ...base, candidateName: "Alex Example", indexNumber: "ZZ-0001", code: CODE_A, sparePages: 0,
  }),
};

await Deno.mkdir(OUT, { recursive: true });
const pages: Record<string, number> = {};
for (const [name, bytes] of Object.entries(files)) {
  await Deno.writeFile(new URL(name, OUT), bytes);
  pages[name] = (await PDFDocument.load(bytes)).getPageCount();
}
await Deno.writeTextFile(
  new URL("codes.json", OUT),
  JSON.stringify({ codeA: CODE_A, codeB: CODE_B, pages }, null, 2) + "\n",
);
console.log("wrote fixtures", pages);
