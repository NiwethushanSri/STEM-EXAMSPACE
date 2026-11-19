"use client";

import { useRef, useState } from "react";
import jsQR from "jsqr";
import { Badge, Card } from "@/components/AppShell";
import { parsePagePayload } from "@/lib/paper-payload";
import { createClient } from "@/lib/supabase/client";

/** Longest side of a photo once read, in pixels. Bigger photos are shrunk so memory stays bounded. */
const MAX_SIDE = 3000;
const PDF_SCALE = 2;
/** Most QR codes read from one page or photo. */
const MAX_CODES_PER_PAGE = 6;

type Found = { code: string; page: number };
type Reading = { label: string; position: number; codes: Found[]; unreadable: number };
type Lookup = {
  code: string;
  page: number;
  found: boolean;
  exam_code: string | null;
  exam_title: string | null;
  index_number: string | null;
  page_count: number | null;
  paper_version: number | null;
  current: boolean | null;
};
type Row = { key: string; label: string; position: number; kind: "none" | "unreadable" | "code"; lookup?: Lookup; code?: Found };

/** Reads every QR on a canvas. After each hit its area is painted white so the next one can be found. */
function readCodes(ctx: CanvasRenderingContext2D, w: number, h: number): { codes: Found[]; unreadable: number } {
  const codes: Found[] = [];
  let unreadable = 0;
  for (let i = 0; i < MAX_CODES_PER_PAGE; i++) {
    const img = ctx.getImageData(0, 0, w, h);
    const hit = jsQR(img.data, w, h, { inversionAttempts: "dontInvert" });
    if (!hit) break;
    const parsed = parsePagePayload(hit.data);
    if (parsed) {
      if (!codes.some((c) => c.code === parsed.code && c.page === parsed.page)) codes.push(parsed);
    } else {
      unreadable++;
    }
    const { topLeftCorner: a, topRightCorner: b, bottomRightCorner: c, bottomLeftCorner: d } = hit.location;
    const minX = Math.min(a.x, b.x, c.x, d.x);
    const minY = Math.min(a.y, b.y, c.y, d.y);
    const maxX = Math.max(a.x, b.x, c.x, d.x);
    const maxY = Math.max(a.y, b.y, c.y, d.y);
    ctx.fillStyle = "#fff";
    // A slightly larger box also covers the quiet zone and the finder squares' edges.
    ctx.fillRect(minX - 4, minY - 4, maxX - minX + 8, maxY - minY + 8);
  }
  return { codes, unreadable };
}

function releaseCanvas(canvas: HTMLCanvasElement) {
  canvas.width = 0;
  canvas.height = 0;
}

async function readImage(file: File): Promise<Reading> {
  const bitmap = await createImageBitmap(file);
  const canvas = document.createElement("canvas");
  try {
    const k = Math.min(1, MAX_SIDE / Math.max(bitmap.width, bitmap.height));
    canvas.width = Math.max(1, Math.round(bitmap.width * k));
    canvas.height = Math.max(1, Math.round(bitmap.height * k));
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    if (!ctx) throw new Error("no canvas");
    ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    return { label: file.name, position: 1, ...readCodes(ctx, canvas.width, canvas.height) };
  } finally {
    bitmap.close();
    releaseCanvas(canvas);
  }
}

type PdfPage = {
  getViewport: (o: { scale: number }) => { width: number; height: number };
  render: (o: { canvasContext: CanvasRenderingContext2D; viewport: { width: number; height: number } }) => { promise: Promise<void> };
  cleanup: () => void;
};

/** One page at a time: render, read, release the canvas, then report. */
async function readPdf(file: File, onPage: (page: number, total: number) => void, onReading: (r: Reading) => void) {
  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
  pdfjs.GlobalWorkerOptions.workerSrc = "/pdf.worker.mjs";
  const doc = await pdfjs.getDocument({ data: new Uint8Array(await file.arrayBuffer()) }).promise;
  try {
    for (let n = 1; n <= doc.numPages; n++) {
      onPage(n, doc.numPages);
      const page = (await doc.getPage(n)) as unknown as PdfPage;
      const viewport = page.getViewport({ scale: PDF_SCALE });
      const canvas = document.createElement("canvas");
      canvas.width = Math.ceil(viewport.width);
      canvas.height = Math.ceil(viewport.height);
      const ctx = canvas.getContext("2d", { willReadFrequently: true });
      if (!ctx) throw new Error("no canvas");
      ctx.fillStyle = "#fff";
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      await page.render({ canvasContext: ctx, viewport }).promise;
      const found = readCodes(ctx, canvas.width, canvas.height);
      releaseCanvas(canvas);
      page.cleanup();
      onReading({ label: file.name, position: n, ...found });
    }
  } finally {
    await doc.destroy();
  }
}

/** The lookup answers an array, or {ok:false, code} when it refuses. */
function readLookup(data: unknown): Lookup[] | null {
  return Array.isArray(data) ? (data as Lookup[]) : null;
}

export function ScanCheck() {
  const input = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState("");
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notes, setNotes] = useState<string[]>([]);

  async function run(files: File[]) {
    setBusy(true);
    setError(null);
    setRows(null);
    setNotes([]);
    const readings: Reading[] = [];
    const skipped: string[] = [];
    try {
      for (const file of files) {
        const name = file.name.toLowerCase();
        const isPdf = file.type === "application/pdf" || name.endsWith(".pdf");
        const isHeic = /hei[cf]/.test(file.type) || /\.hei[cf]$/.test(name);
        if (isHeic) {
          skipped.push(`${file.name}: HEIC photos are not supported. Export as JPEG or PNG and try again.`);
          continue;
        }
        try {
          if (isPdf) {
            await readPdf(
              file,
              (n, total) => setProgress(`Reading page ${n} of ${total}`),
              (r) => readings.push(r),
            );
          } else if (file.type === "image/jpeg" || file.type === "image/png" || /\.(jpe?g|png)$/.test(name)) {
            setProgress(`Reading ${file.name}`);
            readings.push(await readImage(file));
          } else {
            skipped.push(`${file.name}: Only JPEG, PNG and PDF files can be checked.`);
          }
        } catch {
          skipped.push(`${file.name}: This file could not be read.`);
        }
      }
      setNotes(skipped);

      const unique = new Map<string, Found>();
      for (const r of readings) for (const c of r.codes) unique.set(`${c.code}.${c.page}`, c);
      let lookups = new Map<string, Lookup>();
      if (unique.size > 0) {
        setProgress("Looking up codes");
        const { data, error: rpcError } = await createClient().rpc("paper_lookup_codes", { p_items: [...unique.values()] });
        const list = rpcError ? null : readLookup(data);
        if (!list) {
          setError("The codes could not be looked up. Please try again.");
          return;
        }
        lookups = new Map(list.map((l) => [`${l.code}.${l.page}`, l]));
      }

      const out: Row[] = [];
      for (const r of readings) {
        const base = `${r.label}#${r.position}`;
        if (r.codes.length === 0) {
          out.push({ key: `${base}-none`, label: r.label, position: r.position, kind: r.unreadable > 0 ? "unreadable" : "none" });
        }
        for (const c of r.codes) {
          out.push({ key: `${base}-${c.code}.${c.page}`, label: r.label, position: r.position, kind: "code", code: c, lookup: lookups.get(`${c.code}.${c.page}`) });
        }
      }
      setRows(out);
    } finally {
      setBusy(false);
      setProgress("");
      if (input.current) input.current.value = "";
    }
  }

  return (
    <Card title="Check a scan">
      <p className="text-sm text-slate-600">
        Upload a photo or a scan of a printed paper to see which copy it is. Nothing is saved: the file is read in this browser and only the codes are looked up.
      </p>
      <div className="mt-3">
        <label htmlFor="scan-file" className="block text-sm font-medium text-slate-700">
          Photo or scan (JPEG, PNG or PDF)
        </label>
        <input
          ref={input}
          id="scan-file"
          type="file"
          multiple
          accept="image/jpeg,image/png,application/pdf,.heic,.heif"
          disabled={busy}
          onChange={(e) => {
            const files = Array.from(e.target.files ?? []);
            if (files.length > 0) void run(files);
          }}
          className="mt-1 block w-full max-w-md text-sm text-slate-700 file:mr-3 file:rounded file:border file:border-slate-300 file:bg-white file:px-3 file:py-1.5 file:text-sm hover:file:bg-slate-50 disabled:opacity-60"
        />
      </div>

      <div aria-live="polite" data-testid="scan-progress" className="mt-3 text-sm text-slate-600">
        {busy ? progress : ""}
      </div>
      {error && (
        <div role="alert" className="mt-3 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">
          {error}
        </div>
      )}
      {notes.map((n) => (
        <div key={n} role="alert" className="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          {n}
        </div>
      ))}

      {rows && rows.length > 0 && (
        <div className="mt-4 overflow-x-auto">
          <table className="w-full text-left text-sm" data-testid="scan-results">
            <thead>
              <tr className="border-b border-slate-200 text-xs text-slate-500">
                <th className="py-2 pr-4 font-medium">File / page</th>
                <th className="py-2 pr-4 font-medium">Exam</th>
                <th className="py-2 pr-4 font-medium">Page</th>
                <th className="py-2 pr-4 font-medium">Index number</th>
                <th className="py-2 font-medium">Version</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <ResultRow key={r.key} row={r} />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}

function ResultRow({ row }: { row: Row }) {
  const where = (
    <td className="py-2 pr-4 align-top">
      <div className="break-all font-medium text-slate-900">{row.label}</div>
      <div className="text-xs text-slate-500">Page {row.position}</div>
    </td>
  );
  if (row.kind === "none" || row.kind === "unreadable") {
    return (
      <tr data-testid="scan-row" className="border-b border-slate-100 last:border-0">
        {where}
        <td colSpan={4} className="py-2 text-amber-800">
          {row.kind === "none" ? `No code found on page ${row.position}` : `The code on page ${row.position} is not a Stem Examspace paper code`}
        </td>
      </tr>
    );
  }
  const l = row.lookup;
  if (!l || !l.found) {
    return (
      <tr data-testid="scan-row" className="border-b border-slate-100 last:border-0">
        {where}
        <td colSpan={4} className="py-2 text-red-800">
          This code is not one of ours.
        </td>
      </tr>
    );
  }
  return (
    <tr data-testid="scan-row" className="border-b border-slate-100 align-top last:border-0">
      {where}
      <td className="py-2 pr-4">
        <div className="text-slate-900">{l.exam_title}</div>
        <div className="text-xs text-slate-500">{l.exam_code}</div>
      </td>
      <td className="py-2 pr-4 whitespace-nowrap">
        Page {row.code?.page} of {l.page_count}
      </td>
      <td className="py-2 pr-4 whitespace-nowrap">{l.index_number ?? "-"}</td>
      <td className="py-2 whitespace-nowrap">
        v{l.paper_version}
        {l.current === false && (
          <span className="ml-2">
            <Badge tone="amber">Older version</Badge>
          </span>
        )}
      </td>
    </tr>
  );
}
