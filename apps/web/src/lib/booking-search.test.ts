import { describe, expect, it } from "vitest";
import { escapeLike, likePattern, searchWords } from "./booking-search";

describe("searchWords", () => {
  it("splits on whitespace and caps the count and length", () => {
    expect(searchWords("  Ada   Lovelace ")).toEqual(["Ada", "Lovelace"]);
    expect(searchWords("a b c d e f")).toEqual(["a", "b", "c", "d"]);
    expect(searchWords("x".repeat(100))[0]).toHaveLength(40);
    expect(searchWords(undefined)).toEqual([]);
    expect(searchWords("   ")).toEqual([]);
  });
  it("strips * (a PostgREST wildcard)", () => {
    expect(searchWords("Al*pha *")).toEqual(["Alpha"]);
    expect(searchWords("***")).toEqual([]);
  });
  it("keeps commas and brackets as plain characters", () => {
    expect(searchWords("a,b),(c")).toEqual(["a,b),(c"]);
  });
});

describe("escapeLike / likePattern", () => {
  const bs = String.fromCharCode(92);
  it("escapes wildcards", () => {
    expect(escapeLike("50%_off" + bs)).toBe("50" + bs + "%" + bs + "_off" + bs + bs);
    expect(likePattern("a_b")).toBe("%a" + bs + "_b%");
  });
});
