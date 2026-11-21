"use client";

import { useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from "react";
import { areaFromDrag, type Area } from "@/lib/hidden-areas";

type Drag = { start: { x: number; y: number }; end: { x: number; y: number }; width: number; height: number };

/**
 * A picture (the children, drawn at the box's full width) with hidden areas shown over it and, unless `onAdd` is
 * left out, a surface to draw new ones with a mouse, finger or Pencil. Areas are fractions (0 to 1) of the picture
 * from its top left, so they mean the same at every zoom. Used for a paper's pages (Task 1) and for one scanned
 * page's full picture in the exception queue.
 */
export function AreaDrawSurface({
  areas,
  onAdd,
  className = "",
  testId = "draw-surface",
  children,
}: {
  areas: Area[];
  onAdd?: (a: Area) => void;
  className?: string;
  testId?: string;
  children: ReactNode;
}) {
  const box = useRef<HTMLDivElement>(null);
  const [drag, setDrag] = useState<Drag | null>(null);
  const drawing = !!onAdd;
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
      data-testid={testId}
      className={`relative select-none overflow-hidden border border-slate-300 bg-white ${drawing ? "cursor-crosshair touch-none" : ""} ${className}`}
      onPointerDown={
        drawing
          ? (e) => {
              e.currentTarget.setPointerCapture(e.pointerId);
              const p = local(e);
              setDrag({ start: p, end: p, width: p.width, height: p.height });
            }
          : undefined
      }
      onPointerMove={
        drawing
          ? (e) => {
              if (drag) setDrag({ ...drag, end: { x: local(e).x, y: local(e).y } });
            }
          : undefined
      }
      onPointerUp={
        drawing
          ? (e) => {
              if (!drag) return;
              const a = areaFromDrag(drag.start, local(e), drag);
              setDrag(null);
              if (a) onAdd(a);
            }
          : undefined
      }
      onPointerCancel={drawing ? () => setDrag(null) : undefined}
    >
      {children}
      {areas.map((a, i) => shown(a, `a${i}`, "bg-slate-900/85 ring-1 ring-slate-900"))}
      {live && shown(live, "live", "border-2 border-dashed border-blue-600 bg-blue-500/20")}
    </div>
  );
}
