import { describe, expect, it } from "vitest";
import { linearForecast } from "./forecast";

describe("linearForecast", () => {
  it("extends a rising series with rounded, increasing points", () => {
    const f = linearForecast([52, 55, 61, 71], 2);
    expect(f.values).toEqual([76, 82]);
    expect(f.values.every((v) => v > 71)).toBe(true);
    expect(f.slope).toBe(6.3);
  });

  it("returns nothing for fewer than two marks", () => {
    expect(linearForecast([60], 2)).toEqual({ values: [], slope: 0 });
  });

  it("clamps forecasts to 0-100", () => {
    expect(linearForecast([80, 90, 100], 3).values).toEqual([100, 100, 100]);
  });
});
