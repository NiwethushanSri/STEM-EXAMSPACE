import { describe, expect, it } from "vitest";
import { parseExamForm, parseRooms } from "./exam-form";

const VENUE = "11111111-2222-3333-4444-555555555555";
const base = {
  subject: "3",
  title: "Maths mock",
  paper: "Paper 1",
  format: "in_person",
  venue: VENUE,
  room: "Hall A",
  startDate: "2027-06-12",
  startTime: "09:00",
  duration: "90",
  seats: "30",
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
        venueId: VENUE,
        room: "Hall A",
        startsAt: "2027-06-12T08:00:00.000Z",
        bookingDeadline: "2027-06-09T16:00:00.000Z",
        durationMinutes: 90,
        seatLimit: 30,
        pricePence: 1550,
      },
    });
  });
  it("online exams drop venue and room; teachers send no price", () => {
    const r = parseExamForm({ ...base, format: "online", price: "" }, { withPrice: false });
    expect(r).toMatchObject({ ok: true, value: { venueId: null, room: null, pricePence: null } });
  });
  it("rejects bad money", () => {
    for (const price of ["-1", "1.234", "", "abc", "1001"]) {
      const r = parseExamForm({ ...base, price }, { withPrice: true });
      expect(r.ok, price).toBe(false);
    }
  });
  it("rejects in-person without venue or room, and a deadline after the start", () => {
    expect(parseExamForm({ ...base, venue: "" }, { withPrice: true }).ok).toBe(false);
    expect(parseExamForm({ ...base, room: "" }, { withPrice: true }).ok).toBe(false);
    expect(parseExamForm({ ...base, deadlineDate: "2027-06-13" }, { withPrice: true }).ok).toBe(false);
  });
  it("rejects a start time that does not exist on the clock change", () => {
    const r = parseExamForm({ ...base, startDate: "2027-03-28", startTime: "01:30", deadlineDate: "2027-03-20" }, { withPrice: true });
    expect(r.ok).toBe(false);
  });
  it("rejects out of range numbers", () => {
    expect(parseExamForm({ ...base, duration: "5" }, { withPrice: true }).ok).toBe(false);
    expect(parseExamForm({ ...base, seats: "0" }, { withPrice: true }).ok).toBe(false);
    expect(parseExamForm({ ...base, seats: "1001" }, { withPrice: true }).ok).toBe(false);
  });
});

describe("parseRooms", () => {
  it("splits lines and commas and drops blanks", () => {
    expect(parseRooms("Hall A\n Hall B ,\r\n\nLab")).toEqual(["Hall A", "Hall B", "Lab"]);
    expect(parseRooms("")).toEqual([]);
  });
});
