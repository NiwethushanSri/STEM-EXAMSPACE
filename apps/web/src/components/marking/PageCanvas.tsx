"use client";

import { useEffect, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from "react";
import { AnnotationLayer } from "@/components/marking/AnnotationLayer";
import { FOCUS, ToolBar, toolName, type ScreenTool } from "@/components/marking/ToolBar";
import { isStamp, type Tool } from "@/lib/annotations";
import { erasedBy, rulerCm, type SavedAnnotation } from "@/lib/marking-model";
import { pinchStep, pointerIntent, type Pt } from "@/lib/marking-pointer";
import { simplifyStroke } from "@/lib/stroke";
import { PAGE_ASPECT } from "@/lib/page-view";
import type { ScreenPage } from "@/lib/marking-screen";

/** The longest text note the database keeps. */
export const TEXT_NOTE_MAX = 500;
/** How far (in screen pixels) a press may wander and still be a tap. */
const TAP_PX = 8;
/** "The pen has never been used": far more than the half second a finger is ignored for after the pen lifts. */
const NEVER = Number.MAX_SAFE_INTEGER;

type Frac = [number, number];
type Gesture =
  | { kind: "draw"; id: number; tool: ScreenTool; points: Frac[] }
  | { kind: "pan"; id: number; x: number; y: number; startX: number; startY: number; target: EventTarget | null }
  | { kind: "pinch"; ids: [number, number]; prev: [Pt, Pt] }
  | { kind: "select"; id: number; x: number; y: number; at: Frac; target: EventTarget | null };

export type PageCanvasProps = {
  page: ScreenPage | null;
  pageIndex: number;
  pageCount: number;
  onPage: (index: number) => void;
  /** The page's signed link, or null while it is asked for (or the page has no picture). */
  url: string | null;
  /** The picture could not be shown, even after asking again. */
  pictureFailed: boolean;
  onPictureError: () => void;
  /** The picture has loaded. */
  onPictureLoad: () => void;
  onRetryPicture: () => void;
  /** This page's annotations (the marker's own: there are no others on screen). */
  annotations: SavedAnnotation[];
  selectedId: string | null;
  onSelect: (id: string | null) => void;
  onPut: (a: SavedAnnotation) => void;
  onErase: (ids: string[]) => void;
  /** The current question: a stamp placed now is stored with it. */
  questionId: string | null;
  tool: ScreenTool;
  onTool: (t: ScreenTool) => void;
  touchDevice: boolean;
  fingerDraw: boolean;
  onFingerDraw: (on: boolean) => void;
  zoom: number;
  onZoom: (z: number) => void;
  onZoomIn: () => void;
  onZoomOut: () => void;
  onFitWidth: () => void;
  canUndo: boolean;
  canRedo: boolean;
  onUndo: () => void;
  onRedo: () => void;
  onDeleteSelected: () => void;
  /** Input has stopped: nothing is drawn or placed; the view still moves. */
  disabled: boolean;
  /** Shown instead of the page (a hold, a change of pictures, marking closed). */
  cover: ReactNode | null;
};

const newId = () => crypto.randomUUID();
const fracPoints = (list: Frac[]) => list.map(([x, y]) => `${x},${y}`).join(" ");

/**
 * The centre: the tool bar, then one page at a time, at the area's width times the zoom (50% to 400%). The page
 * surface takes every pointer (touch-action: none) and asks pointerIntent what it means: the pen draws (palm ignored),
 * one finger moves the page (or draws with "Draw with finger"), two fingers zoom, the mouse draws with the left button
 * and moves the page with the middle one. The select tool never draws: a tap selects the mark under it. Strokes use the
 * coalesced points where the browser has them, are simplified and kept as fractions of the page.
 */
export function PageCanvas(p: PageCanvasProps) {
  const area = useRef<HTMLDivElement>(null);
  const surface = useRef<HTMLDivElement>(null);
  const live = useRef<SVGPolylineElement>(null);
  const [areaWidth, setAreaWidth] = useState(0);
  const [aspects, setAspects] = useState<Record<string, number>>({});
  const [text, setText] = useState<{ x: number; y: number; value: string } | null>(null);
  const [rulerLabel, setRulerLabel] = useState<{ x: number; y: number; cm: number } | null>(null);
  const touches = useRef(new Map<number, Pt>());
  const gesture = useRef<Gesture | null>(null);
  const pen = useRef({ down: false, upAt: null as number | null });
  /** Where the page should stay under the fingers once a pinch's zoom is drawn. */
  const anchor = useRef<{ fx: number; fy: number; mx: number; my: number } | null>(null);
  /** The zoom as the fingers have set it, ahead of the next render (several moves can come before one). */
  const zoomNow = useRef(p.zoom);

  const pageId = p.page?.pageId ?? null;
  const aspect = (pageId && aspects[pageId]) || PAGE_ASPECT;
  const width = Math.max(160, areaWidth - 32) * p.zoom;
  const height = width / aspect;

  useEffect(() => {
    const el = area.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setAreaWidth(el.clientWidth));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // A pinch keeps the point between the fingers where it was; the new size is laid out before this runs.
  useLayoutEffect(() => {
    zoomNow.current = p.zoom;
    const el = area.current;
    const a = anchor.current;
    if (!el || !a) return;
    anchor.current = null;
    el.scrollLeft = a.fx * el.scrollWidth - a.mx;
    el.scrollTop = a.fy * el.scrollHeight - a.my;
  }, [p.zoom]);

  // A new page, a new tool or stopped input ends what was half done.
  useEffect(() => {
    gesture.current = null;
    live.current?.setAttribute("points", "");
  }, [pageId, p.tool, p.disabled]);

  const frac = (clientX: number, clientY: number): Frac => {
    const r = surface.current!.getBoundingClientRect();
    return [Math.min(1, Math.max(0, (clientX - r.left) / r.width)), Math.min(1, Math.max(0, (clientY - r.top) / r.height))];
  };

  const drawLive = (g: Extract<Gesture, { kind: "draw" }>) => {
    const pts = g.tool === "ruler" ? [g.points[0], g.points[g.points.length - 1]] : g.points;
    live.current?.setAttribute("points", fracPoints(pts));
    if (g.tool === "ruler" && pts.length === 2) {
      setRulerLabel({ x: (pts[0][0] + pts[1][0]) / 2, y: (pts[0][1] + pts[1][1]) / 2, cm: rulerCm(pts) });
    }
  };

  const clearLive = () => {
    live.current?.setAttribute("points", "");
    setRulerLabel(null);
  };

  const capture = (e: ReactPointerEvent) => {
    try {
      e.currentTarget.setPointerCapture(e.pointerId);
    } catch {
      // A pointer the browser does not know (a test's or a stylus's own) cannot be captured; the surface still hears it.
    }
  };

  /** The mark under a tap: a stamp or note it hit, else the nearest stroke or ruler within a few pixels. */
  const hitTest = (target: EventTarget | null, at: Frac): string | null => {
    const el = target instanceof Element ? target.closest("[data-annotation-id]") : null;
    if (el && surface.current?.contains(el)) return el.getAttribute("data-annotation-id");
    if (!pageId) return null;
    const hits = erasedBy([at], p.annotations, pageId, 16 / Math.max(1, width));
    return hits[hits.length - 1] ?? null;
  };

  const startPinch = () => {
    const ids = [...touches.current.keys()].slice(-2) as [number, number];
    const pair = ids.map((id) => touches.current.get(id)!) as [Pt, Pt];
    gesture.current = { kind: "pinch", ids, prev: pair };
    clearLive();
  };

  function onPointerDown(e: ReactPointerEvent<HTMLDivElement>) {
    if (text) return;
    const type = e.pointerType === "pen" || e.pointerType === "touch" ? e.pointerType : "mouse";
    if (type === "touch") touches.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    const since = pen.current.upAt === null ? NEVER : performance.now() - pen.current.upAt;
    const intentTool: Tool = p.tool === "eraser" ? "pen" : p.tool;
    const intent = pointerIntent(
      { pointerType: type, button: e.button },
      { tool: intentTool, fingerDraw: p.fingerDraw, penDown: pen.current.down, msSincePenUp: since, touches: touches.current.size },
    );
    if (type === "pen") pen.current.down = true;
    if (type === "mouse" && e.button === 1) e.preventDefault(); // no autoscroll: the middle button moves the page
    const at = frac(e.clientX, e.clientY);

    if (intent === "pinch") return startPinch();
    if (intent === "pan") {
      // A second finger joining a one-finger drag turns it into a pinch (handled above); one finger moves the page.
      capture(e);
      gesture.current = { kind: "pan", id: e.pointerId, x: e.clientX, y: e.clientY, startX: e.clientX, startY: e.clientY, target: e.target };
      return;
    }
    // The pen with the select tool selects; the select tool never draws with the mouse or a finger either.
    if (p.tool === "select" && (intent === "draw" || type === "pen")) {
      gesture.current = { kind: "select", id: e.pointerId, x: e.clientX, y: e.clientY, at, target: e.target };
      return;
    }
    if (intent !== "draw" || p.disabled || !pageId) return;
    capture(e);
    gesture.current = { kind: "draw", id: e.pointerId, tool: p.tool, points: [at] };
  }

  function onPointerMove(e: ReactPointerEvent<HTMLDivElement>) {
    if (touches.current.has(e.pointerId)) touches.current.set(e.pointerId, { x: e.clientX, y: e.clientY });
    const g = gesture.current;
    if (!g) return;
    if (g.kind === "draw" && g.id === e.pointerId) {
      const native = e.nativeEvent;
      const list = typeof native.getCoalescedEvents === "function" ? native.getCoalescedEvents() : [];
      for (const c of list.length > 0 ? list : [native]) g.points.push(frac(c.clientX, c.clientY));
      if (g.tool === "pen" || g.tool === "highlight" || g.tool === "eraser" || g.tool === "ruler") drawLive(g);
    } else if (g.kind === "pan" && g.id === e.pointerId) {
      const el = area.current;
      if (el) {
        el.scrollLeft -= e.clientX - g.x;
        el.scrollTop -= e.clientY - g.y;
      }
      g.x = e.clientX;
      g.y = e.clientY;
    } else if (g.kind === "pinch" && g.ids.includes(e.pointerId)) {
      const a = touches.current.get(g.ids[0]);
      const b = touches.current.get(g.ids[1]);
      const el = area.current;
      if (!a || !b || !el) return;
      const next: [Pt, Pt] = [a, b];
      const step = pinchStep(g.prev, next, zoomNow.current);
      g.prev = next;
      const r = el.getBoundingClientRect();
      const mx = (a.x + b.x) / 2 - r.left;
      const my = (a.y + b.y) / 2 - r.top;
      if (Math.abs(step.zoom - zoomNow.current) > 1e-4) {
        // The point of the page that was between the fingers, as a fraction of the scrolled content, stays under them.
        anchor.current = {
          fx: (el.scrollLeft + mx - step.dx) / Math.max(1, el.scrollWidth),
          fy: (el.scrollTop + my - step.dy) / Math.max(1, el.scrollHeight),
          mx,
          my,
        };
        zoomNow.current = step.zoom;
        p.onZoom(step.zoom);
      } else {
        el.scrollLeft -= step.dx;
        el.scrollTop -= step.dy;
      }
    }
  }

  function finishDraw(g: Extract<Gesture, { kind: "draw" }>) {
    if (!pageId) return;
    const end = g.points[g.points.length - 1];
    const start = g.points[0];
    const px = Math.hypot((end[0] - start[0]) * width, (end[1] - start[1]) * height);
    if (g.tool === "pen" || g.tool === "highlight") {
      const pts = simplifyStroke(g.points);
      if (pts.length >= 2) p.onPut({ id: newId(), page_id: pageId, kind: g.tool, x: pts[0][0], y: pts[0][1], points: pts });
    } else if (g.tool === "ruler") {
      if (px >= TAP_PX) p.onPut({ id: newId(), page_id: pageId, kind: "ruler", x: start[0], y: start[1], points: [start, end] });
    } else if (g.tool === "eraser") {
      const ids = erasedBy(g.points, p.annotations, pageId, Math.max(0.012, 14 / Math.max(1, width)));
      if (ids.length > 0) p.onErase(ids);
    } else if (g.tool === "text") {
      setText({ x: end[0], y: end[1], value: "" });
    } else if (isStamp(g.tool)) {
      p.onPut({ id: newId(), page_id: pageId, kind: g.tool, x: end[0], y: end[1], ...(p.questionId ? { question_id: p.questionId } : {}) });
    }
  }

  function onPointerUp(e: ReactPointerEvent<HTMLDivElement>) {
    touches.current.delete(e.pointerId);
    if (e.pointerType === "pen") {
      pen.current.down = false;
      pen.current.upAt = performance.now();
    }
    const g = gesture.current;
    if (!g) return;
    if (g.kind === "draw" && g.id === e.pointerId) {
      gesture.current = null;
      clearLive();
      if (!p.disabled) finishDraw(g);
    } else if (g.kind === "pan" && g.id === e.pointerId) {
      gesture.current = null;
      // A finger tap with the select tool selects.
      if (p.tool === "select" && Math.hypot(e.clientX - g.startX, e.clientY - g.startY) < TAP_PX) p.onSelect(hitTest(g.target, frac(e.clientX, e.clientY)));
    } else if (g.kind === "pinch" && g.ids.includes(e.pointerId)) {
      // One finger left: the other carries on moving the page.
      const other = g.ids.find((id) => id !== e.pointerId)!;
      const at = touches.current.get(other);
      gesture.current = at ? { kind: "pan", id: other, x: at.x, y: at.y, startX: NaN, startY: NaN, target: null } : null;
    } else if (g.kind === "select" && g.id === e.pointerId) {
      gesture.current = null;
      if (Math.hypot(e.clientX - g.x, e.clientY - g.y) < TAP_PX) p.onSelect(hitTest(g.target, g.at));
    }
  }

  function onPointerCancel(e: ReactPointerEvent<HTMLDivElement>) {
    touches.current.delete(e.pointerId);
    if (e.pointerType === "pen") {
      pen.current.down = false;
      pen.current.upAt = performance.now();
    }
    const g = gesture.current;
    if (g && (("id" in g && g.id === e.pointerId) || (g.kind === "pinch" && g.ids.includes(e.pointerId)))) {
      gesture.current = null;
      clearLive();
      // A pen or highlighter stroke the browser broke off is kept as far as it went; anything else is dropped.
      if (g.kind === "draw" && (g.tool === "pen" || g.tool === "highlight") && g.points.length >= 2 && !p.disabled) finishDraw(g);
    }
  }

  function commitText() {
    if (!text || !pageId) return setText(null);
    const value = text.value.trim();
    if (value && !p.disabled) {
      p.onPut({ id: newId(), page_id: pageId, kind: "text", x: text.x, y: text.y, text: value.slice(0, TEXT_NOTE_MAX), ...(p.questionId ? { question_id: p.questionId } : {}) });
    }
    setText(null);
  }

  const liveStyle =
    p.tool === "highlight"
      ? { stroke: "#facc15", strokeOpacity: 0.4, strokeWidth: 18 }
      : p.tool === "eraser"
        ? { stroke: "#64748b", strokeOpacity: 0.5, strokeWidth: 14 }
        : p.tool === "ruler"
          ? { stroke: "#2563eb", strokeOpacity: 1, strokeWidth: 1.5 }
          : { stroke: "#dc2626", strokeOpacity: 1, strokeWidth: 2.5 };
  const cursor = p.disabled ? "cursor-default" : p.tool === "select" ? "cursor-default" : p.tool === "text" ? "cursor-text" : "cursor-crosshair";

  return (
    <div className="flex min-h-0 min-w-0 flex-1 flex-col">
      <ToolBar
        tool={p.tool}
        onTool={p.onTool}
        touchDevice={p.touchDevice}
        fingerDraw={p.fingerDraw}
        onFingerDraw={p.onFingerDraw}
        canUndo={p.canUndo}
        canRedo={p.canRedo}
        onUndo={p.onUndo}
        onRedo={p.onRedo}
        zoom={p.zoom}
        onZoomIn={p.onZoomIn}
        onZoomOut={p.onZoomOut}
        onFitWidth={p.onFitWidth}
        page={p.pageIndex}
        pages={p.pageCount}
        onPage={p.onPage}
        selected={p.selectedId !== null}
        onDelete={p.onDeleteSelected}
        disabled={p.disabled || p.cover !== null}
      />
      <div ref={area} data-testid="page-area" className="relative min-h-0 flex-1 overflow-auto bg-slate-200 p-4">
        {p.cover ? (
          <div className="mx-auto max-w-lg rounded-lg border border-slate-200 bg-white p-6 text-sm text-slate-800 shadow-sm">{p.cover}</div>
        ) : p.page ? (
          <div className="mx-auto" style={{ width }}>
            <div
              ref={surface}
              data-testid="page-surface"
              role="group"
              aria-label={`Page ${p.pageIndex + 1} of ${p.pageCount}. ${p.disabled ? "" : `Tool: ${toolName(p.tool)}.`}`}
              className={`relative select-none bg-white shadow-md [-webkit-touch-callout:none] ${cursor}`}
              style={{ width, height, touchAction: "none" }}
              onPointerDown={onPointerDown}
              onPointerMove={onPointerMove}
              onPointerUp={onPointerUp}
              onPointerCancel={onPointerCancel}
              onContextMenu={(e) => e.preventDefault()}
            >
              {p.url ? (
                // eslint-disable-next-line @next/next/no-img-element -- a 120-second signed link to a private picture, not optimisable
                <img
                  key={p.url}
                  src={p.url}
                  alt={`Page ${p.pageIndex + 1}`}
                  draggable={false}
                  className="pointer-events-none absolute inset-0 h-full w-full"
                  onLoad={(e) => {
                    const img = e.currentTarget;
                    if (pageId && img.naturalWidth > 0 && img.naturalHeight > 0) {
                      const a = img.naturalWidth / img.naturalHeight;
                      setAspects((m) => (m[pageId] === a ? m : { ...m, [pageId]: a }));
                    }
                    p.onPictureLoad();
                  }}
                  onError={p.onPictureError}
                />
              ) : (
                <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 p-6 text-center text-sm text-slate-700">
                  {!p.page.hasPicture ? (
                    "This page has no marking picture yet."
                  ) : p.pictureFailed ? (
                    <>
                      <span>The picture could not be shown.</span>
                      <button type="button" onClick={p.onRetryPicture} className={`min-h-11 rounded border border-slate-300 bg-white px-4 text-sm font-medium text-slate-900 ${FOCUS}`}>
                        Try again
                      </button>
                    </>
                  ) : (
                    "Loading the page..."
                  )}
                </div>
              )}
              <AnnotationLayer annotations={p.annotations} selectedId={p.selectedId} />
              <svg viewBox="0 0 1 1" preserveAspectRatio="none" className="pointer-events-none absolute inset-0 h-full w-full overflow-visible" aria-hidden="true">
                <polyline ref={live} points="" fill="none" strokeLinecap="round" strokeLinejoin="round" vectorEffect="non-scaling-stroke" {...liveStyle} />
              </svg>
              {rulerLabel && (
                <span
                  className="pointer-events-none absolute -translate-x-1/2 -translate-y-full rounded bg-white/85 px-1 text-sm font-medium text-blue-700"
                  style={{ left: `${rulerLabel.x * 100}%`, top: `${rulerLabel.y * 100}%` }}
                >
                  {rulerLabel.cm} cm
                </span>
              )}
              {text && (
                <textarea
                  autoFocus
                  aria-label="Text note"
                  rows={2}
                  maxLength={TEXT_NOTE_MAX}
                  value={text.value}
                  placeholder="Type the note, then Enter"
                  onPointerDown={(e) => e.stopPropagation()}
                  onChange={(e) => setText({ ...text, value: e.target.value })}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" && !e.shiftKey) {
                      e.preventDefault();
                      commitText();
                    }
                    if (e.key === "Escape") {
                      e.preventDefault();
                      setText(null);
                    }
                  }}
                  onBlur={commitText}
                  className={`absolute z-10 w-64 max-w-[60%] rounded border border-slate-400 bg-white px-2 py-1 text-sm text-red-700 shadow ${FOCUS}`}
                  style={{ left: `${Math.min(text.x, 0.6) * 100}%`, top: `${text.y * 100}%` }}
                />
              )}
            </div>
          </div>
        ) : (
          <p className="text-sm text-slate-700">This script has no pages to mark.</p>
        )}
      </div>
    </div>
  );
}
