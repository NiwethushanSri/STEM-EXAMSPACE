import "server-only";
import type { AccountStatus, AppRole } from "@stem/shared";
import { createClient } from "@/lib/supabase/server";
import type { AccountRow, LinkRequestRow, PendingRow } from "@/lib/account-rules";

type Details = {
  index_number: string | null;
  school: string | null;
  date_of_birth: string | null;
  signup_parent_name: string | null;
  signup_parent_email: string | null;
  requested_by_parent: string | null;
};
type ProfileWithDetails = {
  id: string;
  role: AppRole;
  status: AccountStatus;
  first_name: string;
  last_name: string;
  email: string;
  invite_sent_at: string | null;
  created_at: string;
  student_details: Details | Details[] | null;
};

const fullName = (first: string, last: string) => `${first} ${last}`.trim();
const day = (iso: string) => iso.slice(0, 10);

export type AccountsData = {
  accounts: AccountRow[];
  pending: PendingRow[];
  links: LinkRequestRow[];
};

/**
 * Everything the account screens need, read with the signed-in admin's session (RLS lets owner/admin
 * read all profiles, student details and link requests). Throws on a read error so the page shows the
 * error boundary instead of a misleading empty list.
 */
export async function loadAccounts(): Promise<AccountsData> {
  const supabase = await createClient();
  const [profiles, requests] = await Promise.all([
    supabase
      .from("profiles")
      .select(
        "id, role, status, first_name, last_name, email, invite_sent_at, created_at, student_details!profile_id(index_number, school, date_of_birth, signup_parent_name, signup_parent_email, requested_by_parent)",
      )
      .order("created_at", { ascending: false })
      .limit(1000),
    supabase.from("parent_link_requests").select("id, parent_id, student_id, created_at").order("created_at"),
  ]);
  if (profiles.error) throw new Error(`accounts read failed: ${profiles.error.code ?? "unknown"}`);
  if (requests.error) throw new Error(`link requests read failed: ${requests.error.code ?? "unknown"}`);

  const rows = (profiles.data ?? []) as unknown as ProfileWithDetails[];
  const detailsOf = (p: ProfileWithDetails): Details | null =>
    Array.isArray(p.student_details) ? (p.student_details[0] ?? null) : p.student_details;
  const byId = new Map(rows.map((p) => [p.id, p]));

  const accounts: AccountRow[] = rows.map((p) => ({
    id: p.id,
    role: p.role,
    status: p.status,
    firstName: p.first_name,
    lastName: p.last_name,
    email: p.email,
    inviteSentAt: p.invite_sent_at,
    indexNumber: detailsOf(p)?.index_number ?? null,
  }));

  // Transient invite "shells" have no signup parent email and are not registrations.
  const pending: PendingRow[] = rows
    .filter((p) => p.role === "student" && p.status === "pending" && detailsOf(p)?.signup_parent_email)
    .map((p) => {
      const d = detailsOf(p)!;
      const requester = d.requested_by_parent ? byId.get(d.requested_by_parent) : undefined;
      return {
        id: p.id,
        name: fullName(p.first_name, p.last_name),
        email: p.email,
        school: d.school ?? "",
        dateOfBirth: d.date_of_birth,
        parentName: d.signup_parent_name ?? "",
        parentEmail: d.signup_parent_email ?? "",
        signedUp: day(p.created_at),
        registeredBy: requester
          ? { name: fullName(requester.first_name, requester.last_name), email: requester.email }
          : null,
      };
    });

  const links: LinkRequestRow[] = (requests.data ?? []).flatMap((r) => {
    const parent = byId.get(r.parent_id);
    const child = byId.get(r.student_id);
    if (!parent || !child) return [];
    const d = detailsOf(child);
    return [
      {
        id: r.id,
        parentName: fullName(parent.first_name, parent.last_name),
        parentEmail: parent.email,
        childName: fullName(child.first_name, child.last_name),
        childIndex: d?.index_number ?? null,
        childDob: d?.date_of_birth ?? null,
        requested: day(r.created_at),
      },
    ];
  });

  return { accounts, pending, links };
}
