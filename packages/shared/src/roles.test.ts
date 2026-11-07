import { describe, expect, it } from "vitest";
import { homeFor, roleLabel, type AccountStatus, type AppRole } from "./roles";

const roles: AppRole[] = ["owner", "admin", "teacher", "tutor", "corrector", "student", "parent"];
const statuses: AccountStatus[] = ["unconfirmed", "pending", "profile_incomplete", "active", "suspended"];
const staff: AppRole[] = ["owner", "admin", "teacher", "tutor", "corrector"];

const mobileLearner: Record<AccountStatus, string> = {
  unconfirmed: "/status/unconfirmed",
  pending: "/status/pending",
  profile_incomplete: "/profile/complete",
  active: "/home",
  suspended: "/status/suspended",
};
const webLearner: Record<AccountStatus, string> = {
  unconfirmed: "/account/unconfirmed",
  pending: "/account/pending",
  profile_incomplete: "/account/profile/complete",
  active: "/account/home",
  suspended: "/account/suspended",
};
const webStaffHome: Record<string, string> = {
  owner: "/owner",
  admin: "/admin",
  teacher: "/teacher",
  tutor: "/tutor",
  corrector: "/corrector",
};

function expected(role: AppRole, status: AccountStatus, platform: "web-staff" | "mobile"): string {
  const isStaff = staff.includes(role);
  if (platform === "mobile") return isStaff ? "/use-desktop" : mobileLearner[status];
  if (isStaff) return status === "suspended" ? "/account/suspended" : webStaffHome[role];
  return webLearner[status];
}

describe("homeFor", () => {
  const cases = roles.flatMap((r) =>
    statuses.flatMap((s) => (["web-staff", "mobile"] as const).map((p) => [r, s, p] as const)),
  );
  it("covers 70 combinations", () => expect(cases).toHaveLength(70));
  it.each(cases)("%s / %s / %s", (role, status, platform) => {
    expect(homeFor(role, status, platform)).toBe(expected(role, status, platform));
  });
  it("spot checks", () => {
    expect(homeFor("owner", "active", "web-staff")).toBe("/owner");
    expect(homeFor("parent", "active", "mobile")).toBe("/home");
    expect(homeFor("parent", "suspended", "mobile")).toBe("/status/suspended");
    expect(homeFor("parent", "suspended", "web-staff")).toBe("/account/suspended");
    expect(homeFor("teacher", "active", "mobile")).toBe("/use-desktop");
  });
});

describe("roleLabel", () => {
  it.each([
    ["owner", "Super administrator"],
    ["admin", "Admin"],
    ["teacher", "Teacher"],
    ["tutor", "Tutor"],
    ["corrector", "Exam corrector"],
    ["student", "Student"],
    ["parent", "Parent"],
  ] as const)("%s", (role, label) => expect(roleLabel(role)).toBe(label));
});
