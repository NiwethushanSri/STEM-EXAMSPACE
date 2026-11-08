import type { AccountStatus, AppRole } from "@stem/shared";

/** A row of the all-accounts table (plain data, safe to pass to client components). */
export type AccountRow = {
  id: string;
  role: AppRole;
  status: AccountStatus;
  firstName: string;
  lastName: string;
  email: string;
  inviteSentAt: string | null;
  indexNumber: string | null;
  /** Students only: a parent is linked. */
  hasParent: boolean;
  /** Students only: the parent email typed at sign-up (editable until a parent is linked). */
  signupParentEmail: string | null;
};

export type PendingRow = {
  id: string;
  name: string;
  email: string;
  school: string;
  dateOfBirth: string | null;
  parentName: string;
  parentEmail: string;
  signedUp: string;
  /** Present when a parent registered this child. */
  registeredBy: { name: string; email: string } | null;
};

export type LinkRequestRow = {
  id: string;
  parentName: string;
  parentEmail: string;
  childName: string;
  childIndex: string | null;
  childDob: string | null;
  requested: string;
};

export type Viewer = { id: string; role: "owner" | "admin" };

export const STAFF_ROLES: readonly AppRole[] = ["admin", "teacher", "tutor", "corrector"];

/** Roles the viewer may invite. Mirrors the invite-user function; the server still enforces it. */
export function invitableRoles(viewer: Viewer["role"]): AppRole[] {
  return viewer === "owner" ? ["admin", "teacher", "tutor", "corrector"] : ["teacher", "tutor", "corrector"];
}

export type RowActions = {
  toggleStatus: "suspend" | "reactivate" | null;
  resendInvite: boolean;
  /** Approved student with no parent link: rebuild the parent invite. */
  resendParentInvite: boolean;
  editParentEmail: boolean;
  removeStaff: boolean;
  deleteAccount: boolean;
};

/**
 * Which row actions to show. Mirrors can_manage_account / account-admin: nobody acts on an owner or on
 * themselves, an admin cannot act on another admin. Hiding is a courtesy; the server is the guard.
 */
export function actionsFor(viewer: Viewer, row: AccountRow): RowActions {
  const none: RowActions = { toggleStatus: null, resendInvite: false, resendParentInvite: false, editParentEmail: false, removeStaff: false, deleteAccount: false };
  if (row.id === viewer.id || row.role === "owner") return none;
  if (viewer.role === "admin" && row.role === "admin") return none;
  // Suspend is offered for every live account, including students still awaiting approval or finishing their profile.
  const toggleStatus =
    row.status === "suspended"
      ? "reactivate"
      : row.status === "active" || row.status === "pending" || row.status === "profile_incomplete"
        ? "suspend"
        : null;
  const unlinkedApproved =
    row.role === "student" && (row.status === "profile_incomplete" || row.status === "active") && !row.hasParent;
  return {
    toggleStatus,
    resendInvite: row.role !== "student" && row.status === "active" && row.inviteSentAt === null,
    resendParentInvite: unlinkedApproved,
    editParentEmail: unlinkedApproved,
    removeStaff: STAFF_ROLES.includes(row.role),
    deleteAccount: row.role === "student" || row.role === "parent",
  };
}

/** Whole years between a YYYY-MM-DD date of birth and today (UTC). */
export function ageFrom(dob: string | null, now = new Date()): number | null {
  if (!dob) return null;
  const d = new Date(`${dob}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return null;
  let age = now.getUTCFullYear() - d.getUTCFullYear();
  const m = now.getUTCMonth() - d.getUTCMonth();
  if (m < 0 || (m === 0 && now.getUTCDate() < d.getUTCDate())) age -= 1;
  return age;
}

export const WARNING_TEXT: Record<string, string> = {
  email_in_use: "The parent email is already used by another account, so no parent invite was created.",
  parent_suspended: "The parent account is suspended, so the child was not linked to it.",
  link_blocked: "The parent link was blocked and was not created.",
  stuck: "This parent invite is stuck. Clear the old invite under Troubleshooting, then approve again.",
};

/** Number of rows per page in the all-accounts table. */
export const PAGE_SIZE = 50;

export type AccountFilters = {
  role: AppRole | null;
  status: AccountStatus | null;
  q: string;
  page: number;
};
