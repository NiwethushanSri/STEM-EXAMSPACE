import { describe, expect, it } from "vitest";
import { PAGE_ASPECT, SIGNED_URL_SECONDS, ZOOMS, rotateView, zoomIn, zoomOut } from "./page-view";

describe("zoom", () => {
  it("steps through the zoom levels and stops at either end", () => {
    expect(ZOOMS[0]).toBe(0.5);
    expect(zoomIn(1)).toBe(1.5);
    expect(zoomOut(1)).toBe(0.75);
    expect(zoomIn(ZOOMS[ZOOMS.length - 1])).toBe(ZOOMS[ZOOMS.length - 1]);
    expect(zoomOut(ZOOMS[0])).toBe(ZOOMS[0]);
    expect(zoomIn(1.2)).toBe(1.5);
    expect(zoomOut(1.2)).toBe(1);
  });
});

describe("rotateView", () => {
  it("turns the view a quarter at a time", () => {
    expect(rotateView(0)).toBe(90);
    expect(rotateView(270)).toBe(0);
    expect(rotateView(90, -1)).toBe(0);
    expect(rotateView(0, -1)).toBe(270);
  });
});

describe("constants", () => {
  it("signs links for 300 seconds and knows the A4 page shape", () => {
    expect(SIGNED_URL_SECONDS).toBe(300);
    expect(PAGE_ASPECT).toBeCloseTo(0.7071, 3);
  });
});
