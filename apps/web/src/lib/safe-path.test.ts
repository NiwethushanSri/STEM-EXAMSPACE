import { describe, expect, it } from "vitest";
import { safeNext } from "./safe-path";

describe("safeNext", () => {
  it("accepts internal relative paths", () => {
    expect(safeNext("/exams/abc/book")).toBe("/exams/abc/book");
    expect(safeNext("/account/bookings?x=1")).toBe("/account/bookings?x=1");
  });
  it("rejects external and tricky values", () => {
    for (const bad of ["https://evil.test", "//evil.test", "/\\evil.test", "evil", "", null, undefined, "/a\nb", "javascript:alert(1)"]) {
      expect(safeNext(bad as string | null)).toBeNull();
    }
  });
});
