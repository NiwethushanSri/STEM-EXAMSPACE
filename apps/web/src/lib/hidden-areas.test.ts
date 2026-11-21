import { describe, expect, it } from "vitest";
import { areaFromDrag, clampArea, MAX_AREAS_PER_PAGE, toFraction } from "./hidden-areas";

const view = { width: 400, height: 800 };

describe("toFraction", () => {
  it("turns pixels on the page into fractions of it", () => {
    expect(toFraction({ x: 100, y: 200, w: 200, h: 80 }, view)).toEqual({ x: 0.25, y: 0.25, w: 0.5, h: 0.1 });
  });
  it("is not fooled by a zero-size viewport", () => {
    expect(toFraction({ x: 1, y: 1, w: 1, h: 1 }, { width: 0, height: 0 })).toEqual({ x: 0, y: 0, w: 0, h: 0 });
  });
});

describe("clampArea", () => {
  it("clamps a rectangle dragged past the right and bottom edges", () => {
    expect(clampArea({ x: 0.8, y: 0.9, w: 0.5, h: 0.5 })).toEqual({ x: 0.8, y: 0.9, w: expect.closeTo(0.2, 10), h: expect.closeTo(0.1, 10) });
  });
  it("clamps a rectangle dragged past the left and top edges", () => {
    expect(clampArea({ x: -0.2, y: -0.1, w: 0.5, h: 0.4 })).toEqual({ x: 0, y: 0, w: expect.closeTo(0.3, 10), h: expect.closeTo(0.3, 10) });
  });
  it("keeps everything inside the page", () => {
    const a = clampArea({ x: -5, y: 7, w: 20, h: 20 });
    expect(a.x).toBeGreaterThanOrEqual(0);
    expect(a.x + a.w).toBeLessThanOrEqual(1);
    expect(a.y + a.h).toBeLessThanOrEqual(1);
  });
});

describe("areaFromDrag", () => {
  it("draws from any corner", () => {
    const down = areaFromDrag({ x: 300, y: 400 }, { x: 100, y: 200 }, view);
    expect(down).toEqual({ x: 0.25, y: 0.25, w: 0.5, h: 0.25 });
  });
  it("clamps a drag that leaves the page", () => {
    const a = areaFromDrag({ x: 300, y: 700 }, { x: 900, y: 1500 }, view);
    expect(a).not.toBeNull();
    expect(a!.x + a!.w).toBeCloseTo(1, 10);
    expect(a!.y + a!.h).toBeCloseTo(1, 10);
  });
  it("ignores a zero-size drag and a tap", () => {
    expect(areaFromDrag({ x: 50, y: 50 }, { x: 50, y: 50 }, view)).toBeNull();
    expect(areaFromDrag({ x: 50, y: 50 }, { x: 51, y: 50 }, view)).toBeNull();
  });
  it("ignores a drag that starts and ends outside the same edge", () => {
    expect(areaFromDrag({ x: 500, y: 100 }, { x: 900, y: 300 }, view)).toBeNull();
  });
});

describe("limits", () => {
  it("matches the database limit of 20 areas a page", () => {
    expect(MAX_AREAS_PER_PAGE).toBe(20);
  });
});
