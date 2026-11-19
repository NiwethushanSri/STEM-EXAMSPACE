import { describe, expect, it } from "vitest";
import { centresFullNote, parseBookingChoice } from "./booking-choice";

const UUID = "3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e0f";
const form = (o: Record<string, string>) => {
  const f = new FormData();
  for (const [k, v] of Object.entries(o)) f.set(k, v);
  return f;
};

describe("parseBookingChoice", () => {
  it("asks for nothing extra when the form sends nothing", () => {
    expect(parseBookingChoice(form({}))).toEqual({ ok: true, sitting: null, centre: null });
  });
  it("reads a sitting and a centre", () => {
    expect(parseBookingChoice(form({ sitting: "centre", centre: UUID }))).toEqual({ ok: true, sitting: "centre", centre: UUID });
    expect(parseBookingChoice(form({ sitting: "home" }))).toEqual({ ok: true, sitting: "home", centre: null });
  });
  it("refuses an unknown sitting or a centre that is not an id", () => {
    expect(parseBookingChoice(form({ sitting: "online" })).ok).toBe(false);
    expect(parseBookingChoice(form({ centre: "nope" })).ok).toBe(false);
  });
});

describe("centresFullNote", () => {
  it("says so when every centre of an exam sat at the centre or at home is full", () => {
    expect(centresFullNote("both", [{ seats_left: 0 }, { seats_left: 0 }])).toBe("All centres are full. Choose At home.");
    expect(centresFullNote("both", [{ seats_left: 0 }])).toBe("The centre is full. Choose At home.");
    expect(centresFullNote("both", [])).toBe("The centre is full. Choose At home.");
  });
  it("says nothing while a centre has a seat", () => {
    expect(centresFullNote("both", [{ seats_left: 0 }, { seats_left: 1 }])).toBeNull();
  });
  it("says nothing for a centre-only or home-only exam (the page handles those)", () => {
    expect(centresFullNote("in_person", [{ seats_left: 0 }])).toBeNull();
    expect(centresFullNote("online", [])).toBeNull();
  });
});
