import { describe, expect, it } from "vitest";
import { normaliseIndexNumber } from "./index-number";

describe("normaliseIndexNumber", () => {
  it.each([
    "SE-2026-0142", "se-2026-0142", "SE 2026 0142", "SE-2026 0142", "se 2026-0142", " SE2026-0142 ", "se20260142", "SE - 2026 - 0142",
  ])("%s -> SE-2026-0142", (raw) => {
    expect(normaliseIndexNumber(raw)).toBe("SE-2026-0142");
  });
  it("keeps longer sequences", () => expect(normaliseIndexNumber("se 2026 00142")).toBe("SE-2026-00142"));
  it("leaves non-index text recognisably wrong", () => {
    expect(normaliseIndexNumber("a b")).toBe("AB");
    expect(normaliseIndexNumber("SE-26-1")).toBe("SE-26-1");
  });
});
