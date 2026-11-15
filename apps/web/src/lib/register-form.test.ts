import { describe, expect, it } from "vitest";
import { ageOn, checkRegistration, validPhone, type RegisterFields } from "./register-form";

const TODAY = new Date("2026-11-15T12:00:00.000Z");

const ok: RegisterFields = {
  first: "Amara",
  last: "Perera",
  dob: "2009-03-12",
  school: "Kingsbury High School",
  email: "amara@example.com",
  pname: "Nimal Perera",
  pemail: "nimal@example.com",
  pphone: "07700 900123",
};

describe("ageOn", () => {
  it("counts whole years, before and after the birthday", () => {
    expect(ageOn("2009-11-15", TODAY)).toBe(17);
    expect(ageOn("2009-11-16", TODAY)).toBe(16);
  });
  it("rejects unreal and future dates", () => {
    expect(ageOn("2009-02-30", TODAY)).toBeNull();
    expect(ageOn("2027-01-01", TODAY)).toBeNull();
    expect(ageOn("12/03/2009", TODAY)).toBeNull();
  });
});

describe("validPhone", () => {
  it("matches the server's rule: 10 to 15 digits with common separators", () => {
    expect(validPhone("07700 900123")).toBe(true);
    expect(validPhone("(020) 7946-0958")).toBe(true);
    expect(validPhone("077009001")).toBe(false);
    expect(validPhone("+1234567890123456")).toBe(false);
    expect(validPhone("44+7700900123")).toBe(false);
  });
});

describe("checkRegistration", () => {
  it("passes a complete, valid form", () => {
    expect(checkRegistration(ok, TODAY)).toEqual({});
  });
  it("asks for every missing field", () => {
    const e = checkRegistration({ first: "", last: "", dob: "", school: "", email: "", pname: "", pemail: "", pphone: "" }, TODAY);
    expect(Object.keys(e).sort()).toEqual(["dob", "email", "first", "last", "pemail", "pname", "pphone", "school"]);
  });
  it("needs a real parent phone number", () => {
    expect(checkRegistration({ ...ok, pphone: "+44 7700 900123" }, TODAY).pphone).toBeUndefined();
    expect(checkRegistration({ ...ok, pphone: "07700 9001" }, TODAY).pphone).toMatch(/valid phone/);
    expect(checkRegistration({ ...ok, pphone: "call after 6" }, TODAY).pphone).toMatch(/valid phone/);
  });
  it("keeps the age between 8 and 25, as the server does", () => {
    expect(checkRegistration({ ...ok, dob: "2020-01-01" }, TODAY).dob).toMatch(/between 8 and 25/);
    expect(checkRegistration({ ...ok, dob: "1990-01-01" }, TODAY).dob).toMatch(/between 8 and 25/);
  });
  it("needs a parent email different from the student's", () => {
    expect(checkRegistration({ ...ok, pemail: "AMARA@example.com" }, TODAY).pemail).toMatch(/different email/);
  });
  it("matches the server's length limits", () => {
    expect(checkRegistration({ ...ok, first: "x".repeat(81) }, TODAY).first).toMatch(/80/);
    expect(checkRegistration({ ...ok, school: "x".repeat(121) }, TODAY).school).toMatch(/120/);
  });
});
