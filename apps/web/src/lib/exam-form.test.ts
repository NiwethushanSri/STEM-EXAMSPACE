import { describe, expect, it } from "vitest";
import { parseExamForm, parseRooms, SITTING_LABEL, SITTING_MODE_LABEL } from "./exam-form";

const VENUE = "11111111-2222-3333-4444-555555555555";
const base = {
  subject: "3",
  title: "Maths mock",
  paper: "Paper 1",
  format: "in_person",
  "centre.0.venue": VENUE,
  "centre.0.room": "Hall A",
  "centre.0.seats": "30",
  startDate: "2027-06-12",
  startTime: "09:00",
  duration: "90",
  price: "15.50",
  deadlineDate: "2027-06-09",
  deadlineTime: "17:00",
};

describe("parseExamForm", () => {
  it("converts a London summer exam to UTC and the price to pence", () => {
    const r = parseExamForm(base, { withPrice: true });
    expect(r).toMatchObject({
      ok: true,
      value: {
        id: null,
        subjectId: 3,
        centres: [{ venueId: VENUE, room: "Hall A", seatLimit: 30 }],
        startsAt: "2027-06-12T08:00:00.000Z",
        bookingDeadline: "2027-06-09T16:00:00.000Z",
        durationMinutes: 90,
        pricePence: 1550,
      },
    });
  });
  it("online_exam_drops_centres", () => {
    const r = parseExamForm({ ...base, format: "online", price: "" }, { withPrice: false });
    expect(r).toMatchObject({ ok: true, value: { centres: [], pricePence: null } });
  });
  it("in_person_needs_at_least_one_centre", () => {
    const none = Object.fromEntries(Object.entries(base).filter(([k]) => !k.startsWith("centre.")));
    expect(parseExamForm(none, { withPrice: true }).ok).toBe(false);
    expect(parseExamForm({ ...none, format: "both" }, { withPrice: true }).ok).toBe(false);
    expect(parseExamForm({ ...base, "centre.0.venue": "" }, { withPrice: true }).ok).toBe(false);
    expect(parseExamForm({ ...base, "centre.0.room": "" }, { withPrice: true }).ok).toBe(false);
  });
  it("both_keeps_two_centres", () => {
    const id = "99999999-2222-3333-4444-555555555555";
    const r = parseExamForm(
      { ...base, format: "both", "centre.1.venue": VENUE, "centre.1.room": "Hall B", "centre.1.seats": "12", "centre.1.id": id },
      { withPrice: true },
    );
    expect(r).toMatchObject({
      ok: true,
      value: {
        format: "both",
        centres: [
          { venueId: VENUE, room: "Hall A", seatLimit: 30 },
          { id, venueId: VENUE, room: "Hall B", seatLimit: 12 },
        ],
      },
    });
  });
  it("rejects_duplicate_centre", () => {
    const r = parseExamForm({ ...base, "centre.1.venue": VENUE, "centre.1.room": "Hall A", "centre.1.seats": "5" }, { withPrice: true });
    expect(r.ok).toBe(false);
  });
  it("rejects_centre_seats_out_of_range", () => {
    for (const seats of ["0", "1001", "", "x"]) {
      expect(parseExamForm({ ...base, "centre.0.seats": seats }, { withPrice: true }).ok, seats).toBe(false);
    }
  });
  it("uses_the_agreed_sitting_words", () => {
    expect(SITTING_LABEL).toEqual({ in_person: "At the centre", online: "At home", both: "At the centre or at home" });
    expect(SITTING_MODE_LABEL).toEqual({ centre: "At the centre", home: "At home" });
  });
  it("rejects bad money", () => {
    for (const price of ["-1", "1.234", "", "abc", "1001"]) {
      const r = parseExamForm({ ...base, price }, { withPrice: true });
      expect(r.ok, price).toBe(false);
    }
  });
  it("rejects a deadline after the start", () => {
    expect(parseExamForm({ ...base, deadlineDate: "2027-06-13" }, { withPrice: true }).ok).toBe(false);
  });
  it("rejects a start time that does not exist on the clock change", () => {
    const r = parseExamForm({ ...base, startDate: "2027-03-28", startTime: "01:30", deadlineDate: "2027-03-20" }, { withPrice: true });
    expect(r.ok).toBe(false);
  });
  it("rejects out of range numbers", () => {
    expect(parseExamForm({ ...base, duration: "5" }, { withPrice: true }).ok).toBe(false);
  });
});

describe("parseExamForm kept instants and bad fields", () => {
  // 01:30 on 31 Oct 2027 happens twice; 01:30Z is the second (GMT) one, 00:30Z the first (BST).
  const repeated = { ...base, startDate: "2027-10-31", startTime: "01:30", deadlineDate: "2027-10-25", deadlineTime: "09:00" };
  it("keeps the stored instant when the inputs were not changed", () => {
    const r = parseExamForm({ ...repeated, startsAtKeep: "2027-10-31T01:30:00+00:00" }, { withPrice: true });
    expect(r).toMatchObject({ ok: true, value: { startsAt: "2027-10-31T01:30:00.000Z" } });
  });
  it("converts normally without a kept instant", () => {
    const r = parseExamForm(repeated, { withPrice: true });
    expect(r).toMatchObject({ ok: true, value: { startsAt: "2027-10-31T00:30:00.000Z" } });
  });
  it("ignores a kept instant that does not match the inputs", () => {
    const r = parseExamForm({ ...repeated, startsAtKeep: "2027-11-05T10:00:00Z" }, { withPrice: true });
    expect(r).toMatchObject({ ok: true, value: { startsAt: "2027-10-31T00:30:00.000Z" } });
  });
  it("keeps the deadline instant too", () => {
    const r = parseExamForm({ ...base, startDate: "2027-10-31", startTime: "09:00", deadlineDate: "2027-10-31", deadlineTime: "01:30", deadlineKeep: "2027-10-31T01:30:00Z" }, { withPrice: true });
    expect(r).toMatchObject({ ok: true, value: { bookingDeadline: "2027-10-31T01:30:00.000Z" } });
  });
  it("treats non-text fields as invalid input instead of throwing", () => {
    const file = new Blob(["x"]) as unknown as string;
    expect(parseExamForm({ ...base, title: file }, { withPrice: true }).ok).toBe(false);
    expect(parseExamForm({ ...base, price: 15 as unknown as string }, { withPrice: true }).ok).toBe(false);
    expect(parseExamForm(null as unknown as Record<string, string>, { withPrice: true }).ok).toBe(false);
  });
});

describe("parseRooms", () => {
  it("splits on lines only, keeps commas, drops blanks", () => {
    expect(parseRooms("Hall A\n Hall B \r\n\nLab")).toEqual(["Hall A", "Hall B", "Lab"]);
    expect(parseRooms("Hall A, East\nLab")).toEqual(["Hall A, East", "Lab"]);
    expect(parseRooms("")).toEqual([]);
  });
});
