import { describe, expect, it } from "vitest";
import { ZOOM_MAX, ZOOM_MIN, isPhone, pinchStep, pointerIntent } from "./marking-pointer";

const ctx = { tool: "pen" as const, fingerDraw: false, penDown: false, msSincePenUp: 10_000, touches: 1 };
const touch = { pointerType: "touch" as const, button: 0 };
const pen = { pointerType: "pen" as const, button: 0 };
const mouse = (button: number) => ({ pointerType: "mouse" as const, button });
type Pair = [{ x: number; y: number }, { x: number; y: number }];

describe("pointer rules", () => {
  it("pen_draws_even_with_fingers_down", () => {
    expect(pointerIntent(pen, { ...ctx, touches: 2 })).toBe("draw");
    expect(pointerIntent(pen, { ...ctx, tool: "tick" })).toBe("draw");
    expect(pointerIntent(pen, { ...ctx, tool: "select" })).toBe("ignore");
  });

  it("touch_while_pen_down_is_ignored", () => {
    expect(pointerIntent(touch, { ...ctx, penDown: true })).toBe("ignore");
    expect(pointerIntent(touch, { ...ctx, penDown: true, touches: 2 })).toBe("ignore");
    expect(pointerIntent(touch, { ...ctx, msSincePenUp: 0 })).toBe("ignore");
    expect(pointerIntent(touch, { ...ctx, msSincePenUp: 499 })).toBe("ignore");
    expect(pointerIntent(touch, { ...ctx, msSincePenUp: 500 })).toBe("pan");
  });

  it("finger_pans_with_a_draw_tool_selected", () => {
    for (const tool of ["pen", "highlight", "tick", "text", "ruler"] as const) {
      expect(pointerIntent(touch, { ...ctx, tool })).toBe("pan");
    }
  });

  it("two_fingers_pinch", () => {
    expect(pointerIntent(touch, { ...ctx, touches: 2 })).toBe("pinch");
    expect(pointerIntent(touch, { ...ctx, touches: 2, fingerDraw: true })).toBe("pinch");
  });

  it("finger_draws_only_with_the_switch_on", () => {
    expect(pointerIntent(touch, { ...ctx, fingerDraw: false })).toBe("pan");
    expect(pointerIntent(touch, { ...ctx, fingerDraw: true })).toBe("draw");
  });

  it("mouse button 0 draws and button 1 pans", () => {
    expect(pointerIntent(mouse(0), ctx)).toBe("draw");
    expect(pointerIntent(mouse(1), ctx)).toBe("pan");
    expect(pointerIntent(mouse(2), ctx)).toBe("ignore");
  });

  it("pinch_zoom_is_clamped", () => {
    const a: Pair = [{ x: 0, y: 0 }, { x: 100, y: 0 }];
    const wide: Pair = [{ x: 0, y: 0 }, { x: 1000, y: 0 }];
    expect(pinchStep(a, wide, 2).zoom).toBe(ZOOM_MAX);
    expect(pinchStep(wide, a, 1).zoom).toBe(ZOOM_MIN);
    expect(pinchStep(a, [{ x: 0, y: 0 }, { x: 150, y: 0 }], 1).zoom).toBeCloseTo(1.5);
    expect(pinchStep(a, [{ x: 10, y: 20 }, { x: 110, y: 20 }], 1)).toEqual({ zoom: 1, dx: 10, dy: 20 });
    expect(ZOOM_MIN).toBe(0.5);
    expect(ZOOM_MAX).toBe(4);
  });

  it("is_phone_under_600", () => {
    expect(isPhone(599)).toBe(true);
    expect(isPhone(600)).toBe(false);
  });
});
