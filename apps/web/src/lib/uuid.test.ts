import { describe, expect, it } from "vitest";
import { isUuid } from "./uuid";

describe("isUuid", () => {
  it("accepts a canonical id in either case", () => {
    expect(isUuid("11111111-2222-3333-4444-555555555555")).toBe(true);
    expect(isUuid("ABCDEF12-2222-3333-4444-555555555555")).toBe(true);
  });
  it.each(["", "abc", "11111111-2222-3333-4444-55555555555", "11111111-2222-3333-4444-5555555555555", "g1111111-2222-3333-4444-555555555555", "../etc/passwd", "11111111-2222-3333-4444-555555555555\n"])(
    "rejects %j",
    (v) => {
      expect(isUuid(v)).toBe(false);
    },
  );
  it("rejects non-strings", () => {
    expect(isUuid(undefined)).toBe(false);
    expect(isUuid(5)).toBe(false);
  });
});
