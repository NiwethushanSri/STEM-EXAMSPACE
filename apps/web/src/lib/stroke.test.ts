import { describe, expect, it } from "vitest";
import { simplifyStroke } from "./stroke";

describe("simplifyStroke", () => {
  it("simplify_keeps_ends_and_caps_points", () => {
    const line: [number, number][] = Array.from({ length: 500 }, (_, i) => [i / 499, 0.5]);
    expect(simplifyStroke(line)).toEqual([[0, 0.5], [1, 0.5]]);

    const wave: [number, number][] = Array.from({ length: 6000 }, (_, i) => [i / 5999, 0.5 + 0.3 * Math.sin(i / 3)]);
    const out = simplifyStroke(wave);
    expect(out.length).toBeLessThanOrEqual(1500);
    expect(out[0]).toEqual(wave[0]);
    expect(out[out.length - 1]).toEqual(wave[wave.length - 1]);
    const tight = simplifyStroke(wave, 0.0008, 50);
    expect(tight.length).toBeLessThanOrEqual(50);
    expect(tight.length).toBeGreaterThanOrEqual(2);
  });

  it("keeps a corner and short strokes", () => {
    expect(simplifyStroke([[0, 0]])).toEqual([[0, 0]]);
    expect(simplifyStroke([[0, 0], [1, 1]])).toEqual([[0, 0], [1, 1]]);
    expect(simplifyStroke([[0, 0], [0.5, 0.5], [1, 0]])).toEqual([[0, 0], [0.5, 0.5], [1, 0]]);
  });
});
