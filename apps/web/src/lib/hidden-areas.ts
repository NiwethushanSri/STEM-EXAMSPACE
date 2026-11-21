// Hidden areas are rectangles over the exam board's own "Candidate name" boxes. They are stored as fractions
// (0 to 1) of the A4 copy page measured from its top left, so they are the same on every candidate's copy and at
// every zoom. The database refuses anything outside the page, so the drawing code clamps first.

export type Area = { x: number; y: number; w: number; h: number };
export type Point = { x: number; y: number };

/** Same limit as set_paper_hidden_areas. */
export const MAX_AREAS_PER_PAGE = 20;

/** Smaller than this (a fraction of the page, about 2 mm across) is a tap or a slip, not an area. */
export const MIN_AREA = 0.004;

/** A rectangle in pixels on the displayed page, as a fraction of that page. */
export function toFraction(rect: Area, viewport: { width: number; height: number }): Area {
  if (!(viewport.width > 0) || !(viewport.height > 0)) return { x: 0, y: 0, w: 0, h: 0 };
  return { x: rect.x / viewport.width, y: rect.y / viewport.height, w: rect.w / viewport.width, h: rect.h / viewport.height };
}

/** Pulls a rectangle back inside the page (0 to 1 each way); the part that was off the page is dropped. */
export function clampArea(a: Area): Area {
  const x0 = Math.min(1, Math.max(0, a.x));
  const y0 = Math.min(1, Math.max(0, a.y));
  const x1 = Math.min(1, Math.max(0, a.x + a.w));
  const y1 = Math.min(1, Math.max(0, a.y + a.h));
  return { x: x0, y: y0, w: Math.max(0, x1 - x0), h: Math.max(0, y1 - y0) };
}

/** The area a drag from `start` to `end` (pixels on the displayed page, any direction) draws, or null when it is
 * too small to mean anything once clamped to the page. */
export function areaFromDrag(start: Point, end: Point, viewport: { width: number; height: number }): Area | null {
  const rect = {
    x: Math.min(start.x, end.x),
    y: Math.min(start.y, end.y),
    w: Math.abs(end.x - start.x),
    h: Math.abs(end.y - start.y),
  };
  const area = clampArea(toFraction(rect, viewport));
  return area.w < MIN_AREA || area.h < MIN_AREA ? null : area;
}
