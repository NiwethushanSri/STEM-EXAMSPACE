import type { Database } from "./database.types";

export type AppRole = Database["public"]["Enums"]["app_role"];
export type AccountStatus = Database["public"]["Enums"]["account_status"];
export type Platform = "web-staff" | "mobile";

const LABELS: Record<AppRole, string> = {
  owner: "Super administrator",
  admin: "Admin",
  teacher: "Teacher",
  tutor: "Tutor",
  corrector: "Exam corrector",
  student: "Student",
  parent: "Parent",
};

export function roleLabel(role: AppRole): string {
  return LABELS[role];
}

const STAFF_HOME: Record<Exclude<AppRole, "student" | "parent">, string> = {
  owner: "/owner",
  admin: "/admin",
  teacher: "/teacher",
  tutor: "/tutor",
  corrector: "/corrector",
};

/** Student and parent landing path by status. Mobile uses bare paths, the web fallback uses /account. */
function learnerPath(status: AccountStatus, mobile: boolean): string {
  const state = mobile ? "/status" : "/account";
  const base = mobile ? "" : "/account";
  switch (status) {
    case "unconfirmed":
      return `${state}/unconfirmed`;
    case "pending":
      return `${state}/pending`;
    case "profile_incomplete":
      return `${base}/profile/complete`;
    case "active":
      return `${base}/home`;
    case "suspended":
      return `${state}/suspended`;
  }
}

/** Where a signed-in user lands. Exhaustive over role, status and platform. */
export function homeFor(role: AppRole, status: AccountStatus, platform: Platform): string {
  if (role === "student" || role === "parent") return learnerPath(status, platform === "mobile");
  if (platform === "mobile") return "/use-desktop";
  return status === "suspended" ? "/account/suspended" : STAFF_HOME[role];
}
