"use client";

import { useEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import { useRouter } from "next/navigation";
import { downloadPaperCopy } from "@stem/shared";
import { Badge } from "@/components/AppShell";
import { savePageLayoutAction } from "@/app/admin/exams/[id]/actions";
import { createClient, functionsEndpoint } from "@/lib/supabase/client";
import { areaFromDrag, MAX_AREAS_PER_PAGE, type Area } from "@/lib/hidden-areas";
import type { PageRole, PaperLayout, PaperVersion } from "@/lib/exam-admin";

const ROLE_LABELS: Record<PageRole, string> = { answer: "Answer page", cover: "Cover", blank: "Blank page", information: "Information" };
const ROLES = Object.keys(ROLE_LABELS) as PageRole[];

type PdfPage = {
  getViewport: (o: { scale: number }) => { width: number; height: number };
  render: (o: { canvasContext: CanvasRenderingContext2D; viewport: { width: number; height: number } }) => { promise: Promise<void>; cancel: () => void };
};
type PdfDoc = { numPages: number; getPage: (n: number) => Promise<PdfPage> };

type DrawnArea = Area & { page: number };

/** Draws one page of the sample copy to a canvas `width` pixels wide. */
function PageCanvas({ doc, page, width }: { doc: PdfDoc; page: number; width: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    let task: { promise: Promise<void>; cancel: () => void } | null = null;
    let cancelled = false;
    (async () => {
      const p = await doc.getPage(page);
      const canvas = ref.current;
      if (cancelled || !canvas) return;
      const natural = p.getViewport({ scale: 1 });
      const viewport = p.getViewport({ scale: width / natural.width });
      canvas.width = Math.floor(viewport.width);
      canvas.height = Math.floor(viewport.height);
      const ctx = canvas.getContext("2d");
      if (!ctx) return;
      task = p.render({ canvasContext: ctx, viewport });
      await task.promise.catch(() => undefined);
    })().catch(() => undefined);
    return () => {
      cancelled = true;
      task?.cancel();
    };
  }, [doc, page, width]);
  return <canvas ref={ref} className="block w-full" aria-hidden="true" />;
}

/** One page, large, with the hidden areas over it and a surface to draw new ones with a mouse, finger or Pencil. */
function DrawSurface({ doc, page, areas, onAdd }: { doc: PdfDoc; page: number; areas: Area[]; onAdd: (a: Area) => void }) {
  const box = useRef<HTMLDivElement>(null);
  const [drag, setDrag] = useState<{ start: { x: number; y: number }; end: { x: number; y: number }; width: number; height: number } | null>(null);
  const local = (e: ReactPointerEvent) => {
    const r = box.current!.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top, width: r.width, height: r.height };
  };
  const live = drag ? areaFromDrag(drag.start, drag.end, drag) : null;
  const shown = (a: Area, key: string, tone: string) => (
    <div key={key} className={`pointer-events-none absolute ${tone}`} style={{ left: `${a.x * 100}%`, top: `${a.y * 100}%`, width: `${a.w * 100}%`, height: `${a.h * 100}%` }} />
  );
  return (
    <div
      ref={box}
      data-testid="draw-surface"
      className="relative mx-auto w-full max-w-[560px] touch-none select-none overflow-hidden border border-slate-300 bg-white"
      onPointerDown={(e) => {
        e.currentTarget.setPointerCapture(e.pointerId);
        const p = local(e);
        setDrag({ start: p, end: p, width: p.width, height: p.height });
      }}
      onPointerMove={(e) => {
        if (drag) setDrag({ ...drag, end: { x: local(e).x, y: local(e).y } });
      }}
      onPointerUp={(e) => {
        if (!drag) return;
        const p = local(e);
        const a = areaFromDrag(drag.start, p, drag);
        setDrag(null);
        if (a) onAdd(a);
      }}
      onPointerCancel={() => setDrag(null)}
    >
      <PageCanvas doc={doc} page={page} width={560} />
      {areas.map((a, i) => shown(a, `a${i}`, "bg-slate-900/85 ring-1 ring-slate-900"))}
      {live && shown(live, "live", "border-2 border-dashed border-blue-600 bg-blue-500/20")}
    </div>
  );
}

/** Which pages of the paper are answer pages, covers, blank pages or information pages, and the hidden areas that
 * stop markers seeing a candidate name. Works on a sample copy of the paper, so areas are fractions of the A4 copy
 * page. */
export function PageRolesPanel({ examId, paper, layout, locked }: { examId: string; paper: PaperVersion; layout: PaperLayout; locked: boolean }) {
  const router = useRouter();
  const [roles, setRoles] = useState<PageRole[]>(() => {
    const byPage = new Map(layout.pages.map((p) => [p.page, p.role]));
    return Array.from({ length: paper.pageCount }, (_, i) => byPage.get(i + 1) ?? "answer");
  });
  const [areas, setAreas] = useState<DrawnArea[]>(() => layout.areas.map(({ page, x, y, w, h }) => ({ page, x, y, w, h })));
  const [doc, setDoc] = useState<PdfDoc | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [hiding, setHiding] = useState(false);
  const [selected, setSelected] = useState(1);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);

  // The sample copy (made by the paper-copy function for admins): every master page on its A4 copy page.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const got = await downloadPaperCopy(createClient(), { paperId: paper.id, kind: "admin_sample" }, functionsEndpoint());
      if ("error" in got) throw new Error(got.error.message);
      const bytes = new Uint8Array(await got.data.blob.arrayBuffer());
      const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
      pdfjs.GlobalWorkerOptions.workerSrc = "/pdf.worker.mjs";
      const loaded = (await pdfjs.getDocument({ data: bytes }).promise) as unknown as PdfDoc;
      if (!cancelled) setDoc(loaded);
    })().catch(() => {
      if (!cancelled) setLoadError("The pages could not be shown. Refresh the page to try again.");
    });
    return () => {
      cancelled = true;
    };
  }, [paper.id]);

  const onPage = (n: number) => areas.filter((a) => a.page === n);
  const dirty =
    JSON.stringify(roles) !== JSON.stringify(Array.from({ length: paper.pageCount }, (_, i) => layout.pages.find((p) => p.page === i + 1)?.role ?? "answer")) ||
    JSON.stringify(areas) !== JSON.stringify(layout.areas.map(({ page, x, y, w, h }) => ({ page, x, y, w, h })));

  async function save() {
    setBusy(true);
    setMessage(null);
    const res = await savePageLayoutAction(
      examId,
      paper.id,
      roles.map((role, i) => ({ page: i + 1, role })),
      areas.map(({ page, x, y, w, h }) => ({ page, x, y, w, h })),
    ).catch(() => ({ ok: false as const, message: "Something went wrong. Please try again." }));
    setBusy(false);
    setMessage({ ok: res.ok, text: res.message });
    if (res.ok) router.refresh();
  }

  return (
    <div data-testid="page-roles" className="mt-6 border-t border-slate-100 pt-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h3 className="flex items-center gap-2 text-sm font-semibold text-slate-800">
            Page roles
            {paper.pagesReviewedAt === null ? <Badge tone="amber">Not checked yet</Badge> : <Badge tone="green">Checked</Badge>}
          </h3>
          <p className="text-xs text-slate-500">
            Say which pages candidates write on. Hide the exam board&apos;s &quot;Candidate name&quot; boxes so markers never see a name. This is shown on a sample copy.
          </p>
        </div>
        <button
          type="button"
          aria-pressed={hiding}
          onClick={() => setHiding((h) => !h)}
          className={`rounded border px-3 py-1.5 text-sm ${hiding ? "border-blue-600 bg-blue-50 text-blue-800" : "border-slate-300 hover:bg-slate-50"}`}
        >
          Hide areas
        </button>
      </div>

      {loadError && (
        <p role="alert" className="mt-3 text-sm text-red-700">
          {loadError}
        </p>
      )}
      {!doc && !loadError && <p className="mt-3 text-sm text-slate-500">Loading the pages...</p>}

      {doc && (
        <div className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4 lg:grid-cols-6">
          {Array.from({ length: doc.numPages }, (_, i) => i + 1).map((n) => {
            const master = n <= paper.pageCount;
            return (
              <div key={n} data-testid="page-thumb" className={`rounded border p-1.5 text-xs ${hiding && selected === n ? "border-blue-600 ring-1 ring-blue-600" : "border-slate-200"}`}>
                <button type="button" onClick={() => setSelected(n)} aria-label={`Page ${n}${hiding ? ", draw on this page" : ""}`} className="relative block w-full overflow-hidden bg-white">
                  <PageCanvas doc={doc} page={n} width={140} />
                  {onPage(n).map((a, i) => (
                    <div key={i} className="absolute bg-slate-900/85" style={{ left: `${a.x * 100}%`, top: `${a.y * 100}%`, width: `${a.w * 100}%`, height: `${a.h * 100}%` }} />
                  ))}
                </button>
                <div className="mt-1 flex items-center justify-between gap-1">
                  <span className="text-slate-500">Page {n}</span>
                  {master ? (
                    <select
                      aria-label={`Role of page ${n}`}
                      value={roles[n - 1]}
                      disabled={locked || busy}
                      onChange={(e) => setRoles((r) => r.map((v, i) => (i === n - 1 ? (e.target.value as PageRole) : v)))}
                      className="min-w-0 rounded border border-slate-300 px-1 py-0.5 text-xs"
                    >
                      {ROLES.map((r) => (
                        <option key={r} value={r}>
                          {ROLE_LABELS[r]}
                        </option>
                      ))}
                    </select>
                  ) : (
                    <span className="text-slate-400">Spare page</span>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      )}

      {doc && hiding && (
        <div className="mt-4">
          <p className="mb-2 text-sm text-slate-700">
            Page {selected}: drag over a name box to hide it. {onPage(selected).length}/{MAX_AREAS_PER_PAGE} areas on this page.
          </p>
          {selected <= paper.pageCount ? (
            <DrawSurface
              doc={doc}
              page={selected}
              areas={onPage(selected)}
              onAdd={(a) => {
                if (onPage(selected).length >= MAX_AREAS_PER_PAGE) return setMessage({ ok: false, text: `A page can have up to ${MAX_AREAS_PER_PAGE} hidden areas.` });
                setAreas((all) => [...all, { ...a, page: selected }]);
              }}
            />
          ) : (
            <p className="text-sm text-slate-500">Spare answer pages are added by the system. Choose one of the paper&apos;s own pages.</p>
          )}
          <ul className="mt-3 divide-y divide-slate-100 text-sm" aria-label="Hidden areas">
            {areas.length === 0 && <li className="py-1 text-slate-500">No hidden areas.</li>}
            {areas.map((a, i) => (
              <li key={i} data-testid="hidden-area" className="flex items-center justify-between gap-2 py-1">
                <span>
                  Page {a.page}: {Math.round(a.x * 100)}% across, {Math.round(a.y * 100)}% down, {Math.round(a.w * 100)}% wide, {Math.round(a.h * 100)}% high
                </span>
                <button type="button" onClick={() => setAreas((all) => all.filter((_, j) => j !== i))} className="rounded border border-red-300 px-2 py-0.5 text-xs font-medium text-red-700 hover:bg-red-50">
                  Delete
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}

      {message && (
        <p role={message.ok ? "status" : "alert"} className={`mt-3 text-sm ${message.ok ? "text-green-800" : "text-red-700"}`}>
          {message.text}
        </p>
      )}
      <div className="mt-3">
        <button type="button" disabled={busy || !doc || (locked && !dirty)} onClick={save} className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
          {busy ? "Saving..." : paper.pagesReviewedAt === null || dirty ? "Save page roles" : "Confirm page roles"}
        </button>
      </div>
    </div>
  );
}
