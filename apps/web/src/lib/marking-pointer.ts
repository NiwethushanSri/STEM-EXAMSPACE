import type { Tool } from "./annotations";

export const ZOOM_MIN = 0.5;
export const ZOOM_MAX = 4;

export type Pt = { x: number; y: number };

export type PointerIntent = "draw" | "pan" | "pinch" | "ignore";

/**
 * What a pointer going down on the page does. The pen always draws (with the select tool it selects, so the screen
 * ignores it here). A finger never draws unless "Draw with finger" is on, and is ignored while the pen is down and for
 * half a second after, so a resting palm does nothing. Two fingers pinch. The mouse draws with the left button and
 * pans with the middle one.
 */
export function pointerIntent(
  e: { pointerType: "mouse" | "pen" | "touch"; button: number },
  ctx: { tool: Tool; fingerDraw: boolean; penDown: boolean; msSincePenUp: number; touches: number },
): PointerIntent {
  if (e.pointerType === "pen") return ctx.tool === "select" ? "ignore" : "draw";
  if (e.pointerType === "touch") {
    if (ctx.penDown || ctx.msSincePenUp < 500) return "ignore";
    if (ctx.touches === 2) return "pinch";
    if (ctx.fingerDraw && ctx.touches === 1) return "draw";
    return "pan";
  }
  if (e.button === 0) return "draw";
  if (e.button === 1) return "pan";
  return "ignore";
}

/** One step of a two-finger gesture: the new zoom (kept between ZOOM_MIN and ZOOM_MAX) and how far the middle moved. */
export function pinchStep(prev: [Pt, Pt], next: [Pt, Pt], zoom: number): { zoom: number; dx: number; dy: number } {
  const before = Math.hypot(prev[0].x - prev[1].x, prev[0].y - prev[1].y);
  const after = Math.hypot(next[0].x - next[1].x, next[0].y - next[1].y);
  const ratio = before > 0 ? after / before : 1;
  const mid = (p: [Pt, Pt]) => ({ x: (p[0].x + p[1].x) / 2, y: (p[0].y + p[1].y) / 2 });
  const a = mid(prev);
  const b = mid(next);
  return { zoom: Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, zoom * ratio)), dx: b.x - a.x, dy: b.y - a.y };
}

export function isPhone(width: number): boolean {
  return width < 600;
}
