import { assertEquals } from "jsr:@std/assert@1";
import { email, normaliseIndex, str, validPastDate } from "./validate.ts";

Deno.test("normaliseIndex tolerates case, spaces and mixed hyphens", () => {
  for (const raw of ["SE-2026-0142", "se-2026-0142", "SE 2026 0142", "SE-2026 0142", "se 2026-0142", " SE2026-0142 ", "se20260142", "SE - 2026 - 0142"]) {
    assertEquals(normaliseIndex(raw), "SE-2026-0142", raw);
  }
  assertEquals(normaliseIndex("SE-2026-00142"), "SE-2026-00142");
  assertEquals(normaliseIndex("nonsense"), "NONSENSE");
  assertEquals(normaliseIndex("SE-26-1"), "SE-26-1");
});

Deno.test("validPastDate: real dates aged 8 to 25 only", () => {
  const now = new Date("2026-11-08T12:00:00Z");
  assertEquals(validPastDate("2012-11-08", now), true); // exactly 14
  assertEquals(validPastDate("2018-11-08", now), true); // exactly 8
  assertEquals(validPastDate("2018-11-09", now), false); // 7 until tomorrow
  assertEquals(validPastDate("2000-11-08", now), false); // 26
  assertEquals(validPastDate("2001-11-09", now), true); // 25
  assertEquals(validPastDate("2012-02-30", now), false);
  assertEquals(validPastDate("2030-01-01", now), false);
  assertEquals(validPastDate("12/11/2012", now), false);
  assertEquals(validPastDate(null, now), false);
});

Deno.test("str and email trim and bound", () => {
  assertEquals(str("  ab ", 1, 5), "ab");
  assertEquals(str("   ", 1, 5), null);
  assertEquals(str("abcdef", 1, 5), null);
  assertEquals(str(5, 1, 5), null);
  assertEquals(email("  A@B.co "), "a@b.co");
  assertEquals(email("nope"), null);
  assertEquals(email("a@b"), null);
  assertEquals(email(`${"a".repeat(250)}@b.co`), null);
});
