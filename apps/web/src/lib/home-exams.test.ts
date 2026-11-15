import { describe, expect, it } from "vitest";
import {
  levelOf,
  toCardData,
  countdownText,
  daysUntil,
  endTime,
  londonDate,
  paperState,
  pickNextPaper,
  placeText,
  subjectGroup,
  type PublicExam,
} from "./home-exams";

function exam(over: Partial<PublicExam> = {}): PublicExam {
  return {
    id: "e1",
    subject: "Maths",
    title: "GCSE Maths",
    paper: "Paper 1 Higher",
    format: "in_person",
    venue: "Main hall",
    room: null,
    starts_at: "2027-06-05T08:00:00.000Z", // 09:00 BST
    duration_minutes: 90,
    price_pence: 3500,
    booking_deadline: "2027-05-28T22:59:00.000Z",
    seats_left: 14,
    ...over,
  };
}

const NOW = new Date("2027-01-10T12:00:00.000Z");

describe("paperState", () => {
  it("is open with more than five seats left", () => {
    expect(paperState(exam({ seats_left: 6 }), NOW)).toBe("open");
  });
  it("is few with five or fewer seats left", () => {
    expect(paperState(exam({ seats_left: 5 }), NOW)).toBe("few");
    expect(paperState(exam({ seats_left: 1 }), NOW)).toBe("few");
  });
  it("is full with no seats left", () => {
    expect(paperState(exam({ seats_left: 0 }), NOW)).toBe("full");
  });
  it("is closed once the booking deadline has passed, even with seats left", () => {
    expect(paperState(exam(), new Date("2027-05-29T00:00:00.000Z"))).toBe("closed");
  });
});

describe("pickNextPaper", () => {
  it("returns null when nothing is published", () => {
    expect(pickNextPaper([], NOW)).toBeNull();
  });
  it("leads with the soonest paper that can still be booked", () => {
    const full = exam({ id: "full", seats_left: 0, starts_at: "2027-06-01T08:00:00.000Z" });
    const open = exam({ id: "open", starts_at: "2027-06-12T08:00:00.000Z" });
    const later = exam({ id: "later", starts_at: "2027-06-20T08:00:00.000Z" });
    expect(pickNextPaper([later, open, full], NOW)?.id).toBe("open");
  });
  it("falls back to the soonest upcoming paper when none can be booked", () => {
    const a = exam({ id: "a", seats_left: 0, starts_at: "2027-06-12T08:00:00.000Z" });
    const b = exam({ id: "b", seats_left: 0, starts_at: "2027-06-05T08:00:00.000Z" });
    expect(pickNextPaper([a, b], NOW)?.id).toBe("b");
  });
  it("ignores papers that have already started", () => {
    const past = exam({ id: "past", starts_at: "2027-01-01T08:00:00.000Z", booking_deadline: "2026-12-30T00:00:00.000Z" });
    expect(pickNextPaper([past], NOW)).toBeNull();
  });
});

describe("subjectGroup", () => {
  it("follows the logo emblem: maths, sciences, computing", () => {
    expect(subjectGroup("Maths")).toBe("maths");
    expect(subjectGroup("Further Maths")).toBe("maths");
    expect(subjectGroup("Physics")).toBe("science");
    expect(subjectGroup("Chemistry")).toBe("science");
    expect(subjectGroup("Biology")).toBe("science");
    expect(subjectGroup("Computer Science")).toBe("computing");
    expect(subjectGroup("TMUA")).toBe("other");
  });
});

describe("daysUntil and countdownText", () => {
  it("counts UK calendar days, not 24-hour blocks", () => {
    // 23:30 UTC on 4 June is already 00:30 on 5 June in London (BST).
    expect(daysUntil("2027-06-05T08:00:00.000Z", new Date("2027-06-04T23:30:00.000Z"))).toBe(0);
    expect(daysUntil("2027-06-05T08:00:00.000Z", new Date("2027-06-04T12:00:00.000Z"))).toBe(1);
    expect(daysUntil("2027-06-05T08:00:00.000Z", new Date("2027-05-26T12:00:00.000Z"))).toBe(10);
  });
  it("reads as plain words", () => {
    expect(countdownText(0)).toBe("Today");
    expect(countdownText(1)).toBe("Tomorrow");
    expect(countdownText(10)).toBe("In 10 days");
  });
});

describe("display helpers", () => {
  it("names the place, or Online", () => {
    expect(placeText(exam({ room: "Room 2" }))).toBe("Main hall, Room 2");
    expect(placeText(exam({ format: "online", venue: null }))).toBe("Online");
    expect(placeText(exam({ venue: null, room: null }))).toBe("Venue to be confirmed");
  });
  it("gives UK date parts and the finish time", () => {
    const d = londonDate("2027-06-05T08:00:00.000Z");
    expect(d).toMatchObject({ weekday: "Saturday", day: "5", month: "June", year: "2027", time: "09:00", short: "Sat 5 Jun" });
    expect(endTime("2027-06-05T08:00:00.000Z", 90)).toBe("10:30");
  });
});

describe("levelOf", () => {
  it("reads the qualification from the exam title", () => {
    expect(levelOf("GCSE Maths")).toBe("GCSE");
    expect(levelOf("A level Maths")).toBe("A level");
    expect(levelOf("A-level Physics")).toBe("A level");
    expect(levelOf("AS Chemistry")).toBe("A level");
    expect(levelOf("Year 9 Science")).toBe("Other");
  });
});

describe("toCardData", () => {
  it("prepares UK-time text and state for a paper card", () => {
    const c = toCardData(exam({ seats_left: 3 }), NOW);
    expect(c).toMatchObject({
      level: "GCSE",
      group: "maths",
      date: "Saturday 5 June",
      time: "09:00–10:30 · 1 h 30 min",
      place: "Main hall",
      price: "£35.00",
      state: "few",
      seatsLeft: 3,
    });
  });
});
