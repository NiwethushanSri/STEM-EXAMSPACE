import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { familyHome, type FamilyBookingRow } from "./family-home";

const NOW = new Date("2026-12-01T10:00:00Z");
const at = (ms: number) => new Date(NOW.getTime() + ms).toISOString();
const DAY = 86_400_000;

const row = (over: Partial<FamilyBookingRow> & { startsAt?: string } = {}): FamilyBookingRow => ({
  id: over.id ?? "b1",
  status: over.status ?? "paid",
  student_id: over.student_id ?? "s1",
  sitting: over.sitting ?? "centre",
  exam: over.exam === undefined ? { title: "Maths Paper 1", starts_at: over.startsAt ?? at(DAY) } : over.exam,
});

describe("familyHome", () => {
  it("splits_upcoming_and_past_by_server_time", () => {
    const { upcoming, past } = familyHome(
      [row({ id: "later", startsAt: at(5 * DAY) }), row({ id: "soon", startsAt: at(60_000) }), row({ id: "started", startsAt: at(-1) })],
      NOW,
    );
    expect(upcoming.map((e) => e.bookingId)).toEqual(["soon", "later"]);
    expect(past.map((e) => e.bookingId)).toEqual(["started"]);
  });

  it("parent_rows_carry_the_childs_first_name", () => {
    const names = new Map([["s1", "Amara"]]);
    const { upcoming } = familyHome([row()], NOW, names);
    expect(upcoming[0]).toMatchObject({ childName: "Amara", examTitle: "Maths Paper 1", sitting: "centre", status: "paid" });
    expect(familyHome([row()], NOW).upcoming[0].childName).toBeNull();
  });

  it("cancelled_and_expired_bookings_are_left_out", () => {
    const { upcoming, past } = familyHome(
      [
        row({ id: "a", status: "cancelled" }),
        row({ id: "b", status: "expired" }),
        row({ id: "c", status: "refunded" }),
        row({ id: "d", status: "awaiting_payment" }),
        row({ id: "e", status: "part_refunded", startsAt: at(-DAY) }),
      ],
      NOW,
    );
    expect(upcoming.map((e) => e.bookingId)).toEqual(["d"]);
    expect(past.map((e) => e.bookingId)).toEqual(["e"]);
  });

  it("puts_past_exams_newest_first_and_skips_rows_without_an_exam", () => {
    const { past } = familyHome(
      [row({ id: "old", startsAt: at(-3 * DAY) }), row({ id: "new", startsAt: at(-DAY) }), row({ id: "none", exam: null })],
      NOW,
    );
    expect(past.map((e) => e.bookingId)).toEqual(["new", "old"]);
  });
});

describe("the family homes", () => {
  it("import_no_sample_data", () => {
    const root = join(__dirname, "..", "app");
    const files: string[] = [];
    const walk = (dir: string) => {
      for (const name of readdirSync(dir)) {
        const p = join(dir, name);
        if (statSync(p).isDirectory()) walk(p);
        else if (/\.(ts|tsx)$/.test(name)) files.push(p);
      }
    };
    walk(join(root, "student"));
    walk(join(root, "parent"));
    expect(files.length).toBeGreaterThan(0);
    for (const f of files) {
      expect(readFileSync(f, "utf8"), f).not.toMatch(/site-data|DEMO_CHILD_ID|getTimetable|getNotices/);
    }
  });
});
