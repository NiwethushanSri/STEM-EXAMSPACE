"use client";

import { useEffect, useRef, useState, type PointerEvent as ReactPointerEvent, type DragEvent } from "react";
import { isStamp, type Annotation, type Tool } from "@/lib/annotations";

type PdfDoc = {
  numPages: number;
  getPage: (n: number) => Promise<{
    getViewport: (o: { scale: number }) => { width: number; height: number };
    render: (o: { canvasContext: CanvasRenderingContext2D; viewport: { width: number; height: number } }) => { promise: Promise<void>; cancel: () => void };
  }>;
};

type Props = {
  bytes: Uint8Array;
  tool: Tool;
  annotations: Annotation[];
  onAnnotationsChange: (next: Annotation[]) => void;
};

type Pt = [number, number];

const RED = "#dc2626";
const GREEN = "#16a34a";
const HIGHLIGHT = "#facc15";
const BLUE = "#2563eb";
const ARC_RADIUS = 40; // protractor arc, in PDF points
const DEFAULT_PAGE = { w: 612, h: 792 }; // US Letter in points, until the page loads

// Shows one PDF page at a time and lets the examiner mark it on top.
export function PdfViewer({ bytes, tool, annotations, onAnnotationsChange }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const surfaceRef = useRef<HTMLDivElement>(null);
  const [doc, setDoc] = useState<PdfDoc | null>(null);
  const [page, setPage] = useState(1);
  const [scale, setScale] = useState(1.1);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [draft, setDraft] = useState<{ x: number; y: number; text: string } | null>(null);
  const [stroke, setStroke] = useState<Pt[] | null>(null);
  const [pending, setPending] = useState<Pt[]>([]);
  const [size, setSize] = useState({ w: 0, h: 0 });
  // Page size in PDF points, used to turn measurements into centimetres and degrees.
  const [pagePts, setPagePts] = useState(DEFAULT_PAGE);

  // Pen, highlighter, ruler and shape are dragged out; the protractor is placed by three clicks.
  const drawKind = tool === "pen" || tool === "highlight" || tool === "ruler" || tool === "box" ? tool : null;

  // Load the document once per PDF.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
        pdfjs.GlobalWorkerOptions.workerSrc = "/pdf.worker.mjs";
        // Copy the bytes: pdf.js may move the buffer to its worker.
        const loaded = await pdfjs.getDocument({ data: bytes.slice() }).promise;
        if (!cancelled) {
          setDoc(loaded as unknown as PdfDoc);
          setPage(1);
        }
      } catch {
        if (!cancelled) setError("This PDF could not be shown.");
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [bytes]);

  // Draw the current page whenever the page or zoom changes.
  useEffect(() => {
    if (!doc || !canvasRef.current) return;
    let task: { promise: Promise<void>; cancel: () => void } | null = null;
    let cancelled = false;
    (async () => {
      const pdfPage = await doc.getPage(page);
      if (cancelled || !canvasRef.current) return;
      const natural = pdfPage.getViewport({ scale: 1 });
      setPagePts({ w: natural.width, h: natural.height });
      const viewport = pdfPage.getViewport({ scale });
      const canvas = canvasRef.current;
      canvas.width = viewport.width;
      canvas.height = viewport.height;
      setSize({ w: viewport.width, h: viewport.height });
      const context = canvas.getContext("2d");
      if (!context) return;
      task = pdfPage.render({ canvasContext: context, viewport });
      await task.promise.catch(() => undefined);
    })();
    return () => {
      cancelled = true;
      task?.cancel();
    };
  }, [doc, page, scale]);

  // Switching tool abandons a protractor that is half placed.
  useEffect(() => {
    setPending([]);
  }, [tool]);

  // Delete removes the selected stamp. Escape cancels a protractor in progress.
  // Ctrl+V pastes clipboard text as a red note.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (draft) return;
      if (e.key === "Escape") setPending([]);
      if ((e.key === "Delete" || e.key === "Backspace") && selected) {
        onAnnotationsChange(annotations.filter((a) => a.id !== selected));
        setSelected(null);
      }
    }
    function onPaste(e: ClipboardEvent) {
      if (draft) return;
      const target = e.target as HTMLElement | null;
      if (target && ["INPUT", "TEXTAREA"].includes(target.tagName)) return;
      const text = e.clipboardData?.getData("text/plain")?.trim();
      if (!text) return;
      onAnnotationsChange([...annotations, { id: newId(), page, kind: "text", x: 0.08, y: 0.08, text }]);
    }
    window.addEventListener("keydown", onKey);
    window.addEventListener("paste", onPaste);
    return () => {
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("paste", onPaste);
    };
  }, [annotations, selected, draft, page, onAnnotationsChange]);

  function fraction(e: { clientX: number; clientY: number }): Pt {
    const rect = surfaceRef.current!.getBoundingClientRect();
    return [
      Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width)),
      Math.min(1, Math.max(0, (e.clientY - rect.top) / rect.height)),
    ];
  }

  // Points as SVG coordinates in PDF points, so curves keep their true shape at any zoom.
  function toSvg(list: Pt[]) {
    return list.map(([x, y]) => `${x * pagePts.w},${y * pagePts.h}`).join(" ");
  }

  function add(item: Omit<Annotation, "id" | "page">) {
    onAnnotationsChange([...annotations, { ...item, id: newId(), page }]);
  }

  // Place a stamp, or open a red note box, where the examiner clicks or drops.
  function placeAt(kind: Tool, at: Pt) {
    if (kind === "text") setDraft({ x: at[0], y: at[1], text: "" });
    else if (isStamp(kind)) add({ kind, x: at[0], y: at[1] });
  }

  function onSurfaceClick(e: ReactPointerEvent<HTMLDivElement>) {
    if (draft) return;
    if (tool === "select") {
      setSelected(null);
      return;
    }
    if (tool === "protractor") {
      // Vertex, then one point on each arm.
      const next = [...pending, fraction(e)];
      if (next.length === 3) {
        add({ kind: "protractor", x: next[0][0], y: next[0][1], points: next });
        setPending([]);
      } else {
        setPending(next);
      }
      return;
    }
    if (drawKind) return;
    placeAt(tool, fraction(e));
  }

  function onPointerDown(e: ReactPointerEvent<HTMLDivElement>) {
    if (!drawKind || draft) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    setStroke([fraction(e)]);
  }

  function onPointerMove(e: ReactPointerEvent<HTMLDivElement>) {
    if (!stroke) return;
    const at = fraction(e);
    setStroke((s) => (s ? [...s, at] : s));
  }

  function onPointerUp() {
    if (stroke && stroke.length > 1 && drawKind) {
      // Pen and highlighter keep every point; ruler and shape keep only their two corners.
      const points = drawKind === "pen" || drawKind === "highlight" ? stroke : [stroke[0], stroke[stroke.length - 1]];
      add({ kind: drawKind, x: stroke[0][0], y: stroke[0][1], points });
    }
    setStroke(null);
  }

  function onDrop(e: DragEvent<HTMLDivElement>) {
    e.preventDefault();
    const kind = e.dataTransfer.getData("text/plain") as Tool;
    if (isStamp(kind) || kind === "text") placeAt(kind, fraction(e));
  }

  function commitDraft() {
    if (!draft) return;
    const text = draft.text.trim();
    if (text) add({ kind: "text", x: draft.x, y: draft.y, text });
    setDraft(null);
  }

  if (error) return <p className="p-6 text-sm text-red-700">{error}</p>;
  if (!doc) return <p className="p-6 text-sm text-slate-500">Loading paper…</p>;

  const pageMarks = annotations.filter((a) => a.page === page);

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between gap-3 border-b border-slate-200 bg-white px-4 py-2 text-sm">
        <div className="flex items-center gap-2">
          <button type="button" disabled={page <= 1} onClick={() => setPage((p) => p - 1)} className="rounded border border-slate-300 px-3 py-1 disabled:opacity-40">
            ‹ Prev
          </button>
          <span className="min-w-24 text-center text-slate-600">Page {page} of {doc.numPages}</span>
          <button type="button" disabled={page >= doc.numPages} onClick={() => setPage((p) => p + 1)} className="rounded border border-slate-300 px-3 py-1 disabled:opacity-40">
            Next ›
          </button>
        </div>
        <div className="flex items-center gap-2">
          <button type="button" onClick={() => setScale((s) => Math.max(0.6, s - 0.2))} className="rounded border border-slate-300 px-3 py-1">−</button>
          <span className="w-14 text-center text-slate-600">{Math.round(scale * 100)}%</span>
          <button type="button" onClick={() => setScale((s) => Math.min(3, s + 0.2))} className="rounded border border-slate-300 px-3 py-1">+</button>
        </div>
      </div>

      <div className="flex-1 overflow-auto bg-slate-200 p-4">
        <div className="relative mx-auto w-max max-w-full">
          <canvas ref={canvasRef} className="block h-auto max-w-full bg-white shadow-md" />

          {/* Marking surface: sits exactly over the page */}
          <div
            ref={surfaceRef}
            className={`absolute left-0 top-0 touch-none ${tool === "select" ? "cursor-default" : drawKind || tool === "protractor" ? "cursor-crosshair" : "cursor-copy"}`}
            style={{ width: size.w, height: size.h }}
            onClick={onSurfaceClick}
            onPointerDown={onPointerDown}
            onPointerMove={onPointerMove}
            onPointerUp={onPointerUp}
            onDragOver={(e) => e.preventDefault()}
            onDrop={onDrop}
          >
            {/* Pen strokes, highlighter, rulers, shapes and protractors, drawn under the stamps */}
            <svg
              viewBox={`0 0 ${pagePts.w} ${pagePts.h}`}
              preserveAspectRatio="none"
              className="pointer-events-none absolute inset-0 h-full w-full"
            >
              {pageMarks.filter((a) => (a.kind === "pen" || a.kind === "highlight") && a.points).map((a) => (
                <polyline
                  key={a.id}
                  points={toSvg(a.points!)}
                  fill="none"
                  {...strokeStyle(a.kind === "highlight" ? "highlight" : "pen")}
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  vectorEffect="non-scaling-stroke"
                />
              ))}
              {pageMarks.filter((a) => a.points && a.kind !== "pen" && a.kind !== "highlight").map((a) => (
                <Measure key={a.id} kind={a.kind} points={a.points!} w={pagePts.w} h={pagePts.h} />
              ))}
              {stroke && stroke.length > 1 && drawKind === "pen" && (
                <polyline points={toSvg(stroke)} fill="none" {...strokeStyle("pen")} strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
              )}
              {stroke && stroke.length > 1 && drawKind === "highlight" && (
                <polyline points={toSvg(stroke)} fill="none" {...strokeStyle("highlight")} strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" />
              )}
              {stroke && stroke.length > 1 && (drawKind === "ruler" || drawKind === "box") && (
                <Measure kind={drawKind} points={[stroke[0], stroke[stroke.length - 1]]} w={pagePts.w} h={pagePts.h} />
              )}
              {pending.length > 0 && (
                <g>
                  <polyline points={toSvg(pending)} fill="none" stroke={BLUE} strokeWidth={1.2} vectorEffect="non-scaling-stroke" />
                  {pending.map(([x, y], i) => (
                    <circle key={i} cx={x * pagePts.w} cy={y * pagePts.h} r={3} fill={BLUE} />
                  ))}
                </g>
              )}
            </svg>

            {/* Stamps and red notes */}
            {pageMarks.filter((a) => a.kind === "text" || isStamp(a.kind)).map((a) => (
              <button
                key={a.id}
                type="button"
                onClick={(e) => {
                  e.stopPropagation();
                  setSelected(a.id);
                }}
                style={{ left: `${a.x * 100}%`, top: `${a.y * 100}%` }}
                className={`absolute -translate-x-1/2 -translate-y-1/2 rounded ${selected === a.id ? "ring-2 ring-blue-500 ring-offset-2" : ""}`}
              >
                {a.kind === "text" ? (
                  <span className="whitespace-pre rounded bg-white/85 px-1 text-sm font-medium" style={{ color: RED }}>{a.text}</span>
                ) : (
                  <Stamp kind={a.kind} />
                )}
              </button>
            ))}

            {/* Red note being typed */}
            {draft && (
              <input
                autoFocus
                value={draft.text}
                onClick={(e) => e.stopPropagation()}
                onPointerDown={(e) => e.stopPropagation()}
                onChange={(e) => setDraft({ ...draft, text: e.target.value })}
                onKeyDown={(e) => {
                  if (e.key === "Enter") commitDraft();
                  if (e.key === "Escape") setDraft(null);
                }}
                onBlur={commitDraft}
                placeholder="Type note, Enter to save"
                style={{ left: `${draft.x * 100}%`, top: `${draft.y * 100}%`, color: RED }}
                className="absolute w-56 rounded border border-red-400 bg-white px-2 py-1 text-sm"
              />
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

function strokeStyle(kind: "pen" | "highlight") {
  return kind === "highlight"
    ? { stroke: HIGHLIGHT, strokeWidth: 18, strokeOpacity: 0.4 }
    : { stroke: RED, strokeWidth: 2.5, strokeOpacity: 1 };
}

type Vec = { x: number; y: number };

// Measuring marks in blue, with readouts: ruler length, shape size, and protractor angle.
// Coordinates are in PDF points; 72 points make an inch.
function Measure({ kind, points, w, h }: { kind: Tool; points: Pt[]; w: number; h: number }) {
  const P: Vec[] = points.map(([x, y]) => ({ x: x * w, y: y * h }));
  const cm = (pt: number) => (pt / 72 * 2.54).toFixed(1);
  const label = { fill: BLUE, fontSize: 11, paintOrder: "stroke", stroke: "white", strokeWidth: 3 } as const;

  if (kind === "ruler" && P.length >= 2) {
    const [a, b] = P;
    const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
    return (
      <g>
        <line x1={a.x} y1={a.y} x2={b.x} y2={b.y} stroke={BLUE} strokeWidth={1.2} />
        <text x={mid.x} y={mid.y - 6} textAnchor="middle" {...label}>{cm(Math.hypot(b.x - a.x, b.y - a.y))} cm</text>
      </g>
    );
  }

  if (kind === "box" && P.length >= 2) {
    const [a, b] = P;
    const x = Math.min(a.x, b.x);
    const y = Math.min(a.y, b.y);
    const bw = Math.abs(b.x - a.x);
    const bh = Math.abs(b.y - a.y);
    return (
      <g>
        <rect x={x} y={y} width={bw} height={bh} fill="none" stroke={BLUE} strokeWidth={1.2} />
        <text x={x} y={y - 5} {...label}>{cm(bw)} × {cm(bh)} cm</text>
      </g>
    );
  }

  if (kind === "protractor" && P.length === 3) {
    const [v, a1, a2] = P;
    const u1 = unit(v, a1);
    const u2 = unit(v, a2);
    const deg = (Math.acos(Math.min(1, Math.max(-1, u1.x * u2.x + u1.y * u2.y))) * 180) / Math.PI;
    // Arc from the first arm to the second, drawn the short way round.
    const p1 = { x: v.x + u1.x * ARC_RADIUS, y: v.y + u1.y * ARC_RADIUS };
    const p2 = { x: v.x + u2.x * ARC_RADIUS, y: v.y + u2.y * ARC_RADIUS };
    const sweep = u1.x * u2.y - u1.y * u2.x > 0 ? 1 : 0;
    // Label sits on the bisector of the two arms.
    let bis = { x: u1.x + u2.x, y: u1.y + u2.y };
    if (Math.hypot(bis.x, bis.y) < 1e-6) bis = { x: -u1.y, y: u1.x };
    const bl = Math.hypot(bis.x, bis.y);
    const labelAt = { x: v.x + (bis.x / bl) * (ARC_RADIUS + 12), y: v.y + (bis.y / bl) * (ARC_RADIUS + 12) };
    return (
      <g>
        <line x1={v.x} y1={v.y} x2={a1.x} y2={a1.y} stroke={BLUE} strokeWidth={1.2} />
        <line x1={v.x} y1={v.y} x2={a2.x} y2={a2.y} stroke={BLUE} strokeWidth={1.2} />
        {deg > 0.5 && (
          <path d={`M ${p1.x} ${p1.y} A ${ARC_RADIUS} ${ARC_RADIUS} 0 0 ${sweep} ${p2.x} ${p2.y}`} fill="none" stroke={BLUE} strokeWidth={1.2} />
        )}
        <text x={labelAt.x} y={labelAt.y} textAnchor="middle" {...label}>{deg.toFixed(0)}°</text>
      </g>
    );
  }

  return null;
}

function unit(from: Vec, to: Vec): Vec {
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const len = Math.hypot(dx, dy) || 1;
  return { x: dx / len, y: dy / len };
}

// Marks drawn in the same colours as on the RM screen: green tick, red cross, wrong sign,
// red caret and red boxed codes. Tools that are not stamps draw nothing here.
export function Stamp({ kind }: { kind: Tool }) {
  if (!isStamp(kind)) return null;
  if (kind === "tick") {
    return (
      <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke={GREEN} strokeWidth="3.2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M4 12.5l5 5L20 6.5" />
      </svg>
    );
  }
  if (kind === "cross") {
    return (
      <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke={RED} strokeWidth="3.2" strokeLinecap="round">
        <path d="M5 5l14 14M19 5L5 19" />
      </svg>
    );
  }
  if (kind === "error") {
    return (
      <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke={RED} strokeWidth="2.6" strokeLinecap="round">
        <circle cx="12" cy="12" r="9" />
        <path d="M8 12h8" />
      </svg>
    );
  }
  if (kind === "caret") {
    return <span className="block text-3xl font-bold leading-none" style={{ color: RED }}>^</span>;
  }
  return (
    <span
      className="block whitespace-nowrap rounded-sm border-2 bg-white/90 px-1 text-sm font-bold leading-snug"
      style={{ color: RED, borderColor: RED }}
    >
      {kind}
    </span>
  );
}

function newId() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}
