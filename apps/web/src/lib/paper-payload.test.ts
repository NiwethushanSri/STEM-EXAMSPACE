import { describe, expect, it } from "vitest";
import { LOOKUP_LIMIT, lookupChunks, parsePagePayload } from "./paper-payload";

describe("parsePagePayload", () => {
  it("parses_valid_payload", () => {
    expect(parsePagePayload("SX1.012345678.3")).toEqual({ code: "012345678", page: 3 });
    expect(parsePagePayload("SX1.ABCDEFGH*.12")).toEqual({ code: "ABCDEFGH*", page: 12 });
    expect(parsePagePayload("SX1.7K2M9QWX~.999")).toEqual({ code: "7K2M9QWX~", page: 999 });
    expect(parsePagePayload("SX1.7K2M9QWX=.1")).toEqual({ code: "7K2M9QWX=", page: 1 });
    expect(parsePagePayload("SX1.7K2M9QWXU.1")).toEqual({ code: "7K2M9QWXU", page: 1 });
    expect(parsePagePayload("SX1.7K2M9QWX$.1")).toEqual({ code: "7K2M9QWX$", page: 1 });
  });
  it("rejects_other_prefix", () => {
    expect(parsePagePayload("SX2.7K2M9QWXA.1")).toBeNull();
    expect(parsePagePayload("https://example.com/7K2M9QWXA.1")).toBeNull();
    expect(parsePagePayload("")).toBeNull();
  });
  it("rejects_page_zero", () => {
    expect(parsePagePayload("SX1.7K2M9QWXA.0")).toBeNull();
    expect(parsePagePayload("SX1.7K2M9QWXA.01")).toBeNull();
    expect(parsePagePayload("SX1.7K2M9QWXA.1000")).toBeNull();
  });
  it("rejects_lowercase_or_extra_text", () => {
    expect(parsePagePayload("SX1.7k2m9qwxa.1")).toBeNull();
    expect(parsePagePayload("SX1.7K2M9QWXA.1 ")).toBeNull();
    expect(parsePagePayload("x SX1.7K2M9QWXA.1")).toBeNull();
    expect(parsePagePayload("SX1.7K2M9QWXA.1\n")).toBeNull();
    expect(parsePagePayload("SX1.7K2M9QWI0.1")).toBeNull(); // I is not in the alphabet
    expect(parsePagePayload("SX1.7K2M9QW.1")).toBeNull(); // 8 characters
  });
});

describe("lookupChunks", () => {
  it("splits_2500_codes_into_three_calls_of_at_most_1000", () => {
    const items = Array.from({ length: 2500 }, (_, i) => i);
    const chunks = lookupChunks(items);
    expect(chunks.map((c) => c.length)).toEqual([1000, 1000, 500]);
    expect(chunks.flat()).toEqual(items);
  });
  it("keeps_the_normal_case_to_one_call_and_none_for_nothing", () => {
    expect(lookupChunks([1, 2, 3])).toHaveLength(1);
    expect(lookupChunks(Array.from({ length: LOOKUP_LIMIT }, (_, i) => i))).toHaveLength(1);
    expect(lookupChunks([])).toEqual([]);
  });
});
