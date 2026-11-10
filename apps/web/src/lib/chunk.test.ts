import { describe, expect, it } from "vitest";
import { chunk } from "./chunk";

describe("chunk", () => {
  it("splits into batches and keeps order", () => {
    expect(chunk([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]]);
    expect(chunk([1, 2], 2)).toEqual([[1, 2]]);
  });
  it("handles empty input", () => {
    expect(chunk([], 100)).toEqual([]);
  });
  it("batches 500 ids into 5 of 100", () => {
    const ids = Array.from({ length: 500 }, (_, i) => i);
    const parts = chunk(ids, 100);
    expect(parts).toHaveLength(5);
    expect(parts.every((p) => p.length === 100)).toBe(true);
    expect(parts.flat()).toEqual(ids);
  });
  it("rejects a bad size", () => {
    expect(() => chunk([1], 0)).toThrow();
  });
});
