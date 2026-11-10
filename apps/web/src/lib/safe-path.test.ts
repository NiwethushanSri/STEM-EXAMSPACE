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

describe("safeNext (encoded and padded tricks)", () => {
  it.each([
    ["/%2F%2Fevil", "/%2F%2Fevil"],
    ["/%5Cevil", "/%5Cevil"],
  ])("handles %s without leaving the site", (raw) => {
    // Percent-encoded slashes stay literal path text on this origin; they are not a host. Either null or a same-origin path is safe.
    const out = safeNext(raw);
    expect(out === null || out.startsWith("/")).toBe(true);
    if (out) expect(new URL(out, "http://x.test").origin).toBe("http://x.test");
  });
  it("rejects tab, backslash-first, leading space and over-long values", () => {
    expect(safeNext("/\t/evil")).toBeNull();
    expect(safeNext("\\/evil")).toBeNull();
    expect(safeNext(" /evil")).toBeNull();
    expect(safeNext("/" + "a".repeat(300))).toBeNull();
  });
});
