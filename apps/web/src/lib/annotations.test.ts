import { describe, expect, it } from "vitest";
import { ANNOTATION_KINDS } from "./annotations";

describe("ANNOTATION_KINDS", () => {
  it("equals the database list exactly", () => {
    expect([...ANNOTATION_KINDS]).toEqual([
      "tick", "cross", "error", "caret", "XP", "SEEN", "SF", "TE", "BP", "AE", "ECF", "L1", "L2", "L3", "POT", "BOD",
      "CON", "pen", "highlight", "text", "ruler",
    ]);
  });
});
