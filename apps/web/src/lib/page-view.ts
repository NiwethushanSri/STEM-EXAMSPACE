/** How the staff page viewer zooms and turns the view. Turning only changes the view: the stored picture and its
 * rotation stay as they are (rotating a page for good comes with the script repository). */

/** Signed links to page pictures last this long; the viewer asks for a new one when the picture fails to load. */
export const SIGNED_URL_SECONDS = 300;

/** Width over height of a stored page picture (A4 portrait, 1654 x 2339 px). */
export const PAGE_ASPECT = 1654 / 2339;

export const ZOOMS = [0.5, 0.75, 1, 1.5, 2, 3] as const;

/** The next zoom level up from z (the largest stays). */
export function zoomIn(z: number): number {
  return ZOOMS.find((v) => v > z) ?? ZOOMS[ZOOMS.length - 1];
}

/** The next zoom level down from z (the smallest stays). */
export function zoomOut(z: number): number {
  return [...ZOOMS].reverse().find((v) => v < z) ?? ZOOMS[0];
}

/** The view turned a quarter clockwise (or anticlockwise with -1): 0, 90, 180 or 270 degrees. */
export function rotateView(degrees: number, direction: 1 | -1 = 1): number {
  return (((degrees + 90 * direction) % 360) + 360) % 360;
}
