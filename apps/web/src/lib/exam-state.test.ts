import { describe, expect, it } from "vitest";
import { isClosed } from "./exam-state";

const exam = { booking_deadline: "2027-06-09T08:00:00Z", starts_at: "2027-06-12T08:00:00Z" };

describe("isClosed", () => {
  it("is open before the deadline", () => expect(isClosed(exam, new Date("2027-06-09T07:59:59Z"))).toBe(false));
  it("is closed at the deadline", () => expect(isClosed(exam, new Date("2027-06-09T08:00:00Z"))).toBe(true));
  it("is closed after the start even if the deadline is later", () => {
    expect(isClosed({ booking_deadline: "2027-06-13T00:00:00Z", starts_at: exam.starts_at }, new Date("2027-06-12T08:00:00Z"))).toBe(true);
  });
});
