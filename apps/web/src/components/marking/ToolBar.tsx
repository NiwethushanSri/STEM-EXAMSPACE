"use client";

import { useEffect, useId, useRef, useState, type ReactNode } from "react";
import { BOX_KINDS, TOOL_LABELS, type StampKind } from "@/lib/annotations";
import type { KeyTool } from "@/lib/marking-keys";
import { ZOOM_MAX, ZOOM_MIN } from "@/lib/marking-pointer";

/** Every tool of the marking screen: the annotation tools, the select tool and the eraser. */
export type ScreenTool = KeyTool;

/** The stamps behind the Stamps button (tick and cross have their own). */
const MORE_STAMPS: StampKind[] = ["error", "caret", ...BOX_KINDS];

export const FOCUS = "focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-600";
const BTN = `inline-flex min-h-11 min-w-11 items-center justify-center gap-1 rounded border px-2 text-sm font-medium disabled:cursor-not-allowed disabled:opacity-40 ${FOCUS}`;
const OFF = "border-slate-300 bg-white text-slate-800 hover:bg-slate-50";
const ON = "border-blue-700 bg-blue-600 text-white";

const TOOL_NAMES: Record<Exclude<ScreenTool, StampKind | "box" | "protractor">, string> = {
  select: "Select",
  pen: "Pen",
  highlight: "Highlighter",
  text: "Text note",
  ruler: "Ruler",
  eraser: "Eraser",
};
const KEYS: Partial<Record<ScreenTool, string>> = { select: "V", tick: "T", cross: "X", pen: "P", highlight: "H", text: "C", ruler: "R", eraser: "E", BOD: "B", ECF: "F", SEEN: "S" };

/** The name a tool is shown and announced by. */
export function toolName(tool: ScreenTool): string {
  if (tool in TOOL_NAMES) return TOOL_NAMES[tool as keyof typeof TOOL_NAMES];
  return TOOL_LABELS[tool as Exclude<ScreenTool, "select" | "eraser">];
}

function Icon({ d }: { d: string }) {
  return (
    <svg aria-hidden="true" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d={d} />
    </svg>
  );
}

const ICONS: Partial<Record<ScreenTool, string>> = {
  select: "M5 3l13 8-6 1.5L9.5 19z",
  tick: "M4 12.5l5 5L20 6.5",
  cross: "M6 6l12 12M18 6L6 18",
  pen: "M4 20l4-1L19 8l-3-3L5 16zM14 7l3 3",
  highlight: "M8 14l-4 4v2h5l2-2M8 14l8-10 4 3-8 10zM8 14l4 3",
  text: "M5 6h14M12 6v13M9 19h6",
  ruler: "M3 16L16 3l5 5L8 21zM7 12l2 2M10 9l2 2M13 6l2 2",
  eraser: "M4 15l9-9 7 7-6 6H8zM10 19h10",
};

function ToolButton({ tool, current, onPick, disabled, children }: { tool: ScreenTool; current: ScreenTool; onPick: (t: ScreenTool) => void; disabled: boolean; children?: ReactNode }) {
  const name = toolName(tool);
  const key = KEYS[tool];
  return (
    <button
      type="button"
      aria-label={name}
      aria-pressed={current === tool}
      title={key ? `${name} (${key})` : name}
      disabled={disabled}
      onClick={() => onPick(tool)}
      className={`${BTN} ${current === tool ? ON : OFF}`}
    >
      {children ?? <Icon d={ICONS[tool] ?? ""} />}
    </button>
  );
}

/** The stamps other than tick and cross, behind one button; the chosen stamp becomes the tool. */
function StampMenu({ current, onPick, disabled }: { current: ScreenTool; onPick: (t: ScreenTool) => void; disabled: boolean }) {
  const [open, setOpen] = useState(false);
  const id = useId();
  const box = useRef<HTMLDivElement>(null);
  const chosen = (MORE_STAMPS as ScreenTool[]).includes(current) ? current : null;
  useEffect(() => {
    if (!open) return;
    const away = (e: PointerEvent) => {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
    };
    const esc = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("pointerdown", away);
    window.addEventListener("keydown", esc);
    return () => {
      window.removeEventListener("pointerdown", away);
      window.removeEventListener("keydown", esc);
    };
  }, [open]);
  return (
    <div ref={box} className="relative">
      <button
        type="button"
        aria-expanded={open}
        aria-controls={id}
        aria-label={chosen ? `Stamps: ${toolName(chosen)}` : "Stamps"}
        title="Stamps (B, F, S)"
        disabled={disabled}
        onClick={() => setOpen((o) => !o)}
        className={`${BTN} ${chosen ? ON : OFF}`}
      >
        {chosen ? (chosen === "error" ? "Wrong sign" : chosen === "caret" ? "^" : chosen) : "Stamps"}
        <svg aria-hidden="true" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
          <path d="M6 9l6 6 6-6" />
        </svg>
      </button>
      {open && (
        <div id={id} role="group" aria-label="Stamps" className="absolute left-0 top-full z-30 mt-1 grid w-64 grid-cols-3 gap-1 rounded border border-slate-200 bg-white p-2 shadow-lg">
          {MORE_STAMPS.map((s) => (
            <button
              key={s}
              type="button"
              aria-pressed={current === s}
              aria-label={toolName(s)}
              onClick={() => {
                onPick(s);
                setOpen(false);
              }}
              className={`${BTN} ${current === s ? ON : OFF}`}
            >
              {s === "error" ? "Wrong sign" : s === "caret" ? "^" : s}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

export type ToolBarProps = {
  tool: ScreenTool;
  onTool: (t: ScreenTool) => void;
  /** Touch devices only: whether one finger draws (otherwise it moves the page). */
  touchDevice: boolean;
  fingerDraw: boolean;
  onFingerDraw: (on: boolean) => void;
  canUndo: boolean;
  canRedo: boolean;
  onUndo: () => void;
  onRedo: () => void;
  zoom: number;
  onZoomIn: () => void;
  onZoomOut: () => void;
  onFitWidth: () => void;
  page: number;
  pages: number;
  onPage: (index: number) => void;
  /** A mark is selected: it can be deleted. */
  selected: boolean;
  onDelete: () => void;
  /** Input has stopped (a hold, a refusal, read only): the marking tools are off; the view still moves. */
  disabled: boolean;
};

/** The tools above the page: select, tick, cross, the stamps, pen, highlighter, text note, ruler, eraser, undo, redo,
 * the page, zoom, and on touch devices "Draw with finger". */
export function ToolBar(p: ToolBarProps) {
  return (
    <div role="toolbar" aria-label="Marking tools" className="flex flex-wrap items-center gap-1 border-b border-slate-200 bg-white px-2 py-1.5">
      <div className="flex flex-wrap items-center gap-1" role="group" aria-label="Tools">
        <ToolButton tool="select" current={p.tool} onPick={p.onTool} disabled={p.disabled} />
        <ToolButton tool="tick" current={p.tool} onPick={p.onTool} disabled={p.disabled} />
        <ToolButton tool="cross" current={p.tool} onPick={p.onTool} disabled={p.disabled} />
        <StampMenu current={p.tool} onPick={p.onTool} disabled={p.disabled} />
        <ToolButton tool="pen" current={p.tool} onPick={p.onTool} disabled={p.disabled} />
        <ToolButton tool="highlight" current={p.tool} onPick={p.onTool} disabled={p.disabled} />
        <ToolButton tool="text" current={p.tool} onPick={p.onTool} disabled={p.disabled} />
        <ToolButton tool="ruler" current={p.tool} onPick={p.onTool} disabled={p.disabled} />
        <ToolButton tool="eraser" current={p.tool} onPick={p.onTool} disabled={p.disabled} />
      </div>
      <span className="mx-1 h-8 w-px bg-slate-200" aria-hidden="true" />
      <div className="flex items-center gap-1" role="group" aria-label="Undo and redo">
        <button type="button" aria-label="Undo" title="Undo (Ctrl+Z)" disabled={p.disabled || !p.canUndo} onClick={p.onUndo} className={`${BTN} ${OFF}`}>
          <Icon d="M9 14L4 9l5-5M4 9h10a6 6 0 010 12h-3" />
        </button>
        <button type="button" aria-label="Redo" title="Redo (Ctrl+Shift+Z)" disabled={p.disabled || !p.canRedo} onClick={p.onRedo} className={`${BTN} ${OFF}`}>
          <Icon d="M15 14l5-5-5-5M20 9H10a6 6 0 000 12h3" />
        </button>
        {p.selected && (
          <button type="button" aria-label="Delete the selected mark" title="Delete the selected mark (Delete)" disabled={p.disabled} onClick={p.onDelete} className={`${BTN} ${OFF}`}>
            <Icon d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13" />
          </button>
        )}
      </div>
      <span className="mx-1 h-8 w-px bg-slate-200" aria-hidden="true" />
      <div className="flex items-center gap-1" role="group" aria-label="Page">
        <button type="button" aria-label="Previous page" title="Previous page (Left arrow)" disabled={p.page <= 0} onClick={() => p.onPage(p.page - 1)} className={`${BTN} ${OFF}`}>
          <Icon d="M15 18l-6-6 6-6" />
        </button>
        <span className="min-w-16 text-center text-sm text-slate-700" aria-live="polite">
          {p.pages === 0 ? "No pages" : `Page ${p.page + 1} of ${p.pages}`}
        </span>
        <button type="button" aria-label="Next page" title="Next page (Right arrow)" disabled={p.page >= p.pages - 1} onClick={() => p.onPage(p.page + 1)} className={`${BTN} ${OFF}`}>
          <Icon d="M9 6l6 6-6 6" />
        </button>
      </div>
      <span className="mx-1 h-8 w-px bg-slate-200" aria-hidden="true" />
      <div className="flex items-center gap-1" role="group" aria-label="Zoom">
        <button type="button" aria-label="Zoom out" title="Zoom out ([)" disabled={p.zoom <= ZOOM_MIN + 1e-6} onClick={p.onZoomOut} className={`${BTN} ${OFF}`}>
          <Icon d="M5 12h14" />
        </button>
        <span data-testid="zoom-figure" className="min-w-12 text-center text-sm tabular-nums text-slate-700">
          {Math.round(p.zoom * 100)}%
        </span>
        <button type="button" aria-label="Zoom in" title="Zoom in (])" disabled={p.zoom >= ZOOM_MAX - 1e-6} onClick={p.onZoomIn} className={`${BTN} ${OFF}`}>
          <Icon d="M12 5v14M5 12h14" />
        </button>
        <button type="button" aria-label="Fit width" title="Fit width (\)" onClick={p.onFitWidth} className={`${BTN} ${OFF}`}>
          <Icon d="M4 12h16M7 9l-3 3 3 3M17 9l3 3-3 3" />
        </button>
      </div>
      {p.touchDevice && (
        <button
          type="button"
          aria-pressed={p.fingerDraw}
          disabled={p.disabled}
          onClick={() => p.onFingerDraw(!p.fingerDraw)}
          className={`${BTN} ${p.fingerDraw ? ON : OFF} px-3`}
        >
          Draw with finger
        </button>
      )}
    </div>
  );
}
