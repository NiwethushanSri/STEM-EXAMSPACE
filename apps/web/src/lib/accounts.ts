import "server-only";
import type { AccountStatus, AppRole } from "@stem/shared";
import { createClient } from "@/lib/supabase/server";
import { requireStaff } from "@/lib/staff-gate";
import {
  PAGE_SIZE,
  STAFF_ROLES,
  type AccountFilters,
  type AccountRow,
  type LinkRequestRow,
  type PendingRow,
} from "@/lib/account-rules";

// Every loader re-checks the caller (active owner/admin) before it queries; RLS is the second guard.
const MANAGERS = ["owner", "admin"] as const;

const fullName = (first: string, last: string) => `${first} ${last}`.trim();
const day = (iso: string) => iso.slice(0, 10);
const one = <T,>(v: T | T[] | null | undefined): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));

type Details = {
  index_number: string | null;
  school: string | null;
  date_of_birth: string | null;
  signup_parent_name: string | null;
  signup_parent_email: string | null;
  requested_by_parent: string | null;
};

function fail(what: string, code: string | undefined): never {
  throw new Error(`${what} read failed: ${code ?? "unknown"}`);
}

/** Students waiting for approval: status pending AND a signup parent email (excludes transient invite shells). */
function pendingQuery(supabase: Awaited<ReturnType<typeof createClient>>, columns: string, head: boolean) {
  return supabase
    .from("profiles")
    .select(columns, { count: "exact", head })
    .eq("role", "student")
    .eq("status", "pending")
    .not("student_details.signup_parent_email", "is", null);
}

export async function loadCounts(): Promise<{ accounts: number; pending: number; links: number }> {
  await requireStaff(MANAGERS);
  const supabase = await createClient();
  const [a, p, l] = await Promise.all([
    supabase.from("profiles").select("*", { count: "exact", head: true }),
    pendingQuery(supabase, "id, student_details!profile_id!inner(profile_id)", true),
    supabase.from("parent_link_requests").select("*", { count: "exact", head: true }),
  ]);
  if (a.error) fail("accounts count", a.error.code);
  if (p.error) fail("pending count", p.error.code);
  if (l.error) fail("link count", l.error.code);
  return { accounts: a.count ?? 0, pending: p.count ?? 0, links: l.count ?? 0 };
}

export async function loadPending(limit?: number): Promise<PendingRow[]> {
  await requireStaff(MANAGERS);
  const supabase = await createClient();
  let q = pendingQuery(
    supabase,
    "id, first_name, last_name, email, created_at, student_details!profile_id!inner(school, date_of_birth, signup_parent_name, signup_parent_email, requested_by_parent)",
    false,
  ).order("created_at", { ascending: true });
  if (limit) q = q.limit(limit);
  const { data, error } = await q;
  if (error) fail("pending", error.code);
  const rows = (data ?? []) as unknown as {
    id: string;
    first_name: string;
    last_name: string;
    email: string;
    created_at: string;
    student_details: Details | Details[];
  }[];

  const requesterIds = [
    ...new Set(rows.map((r) => one(r.student_details)?.requested_by_parent).filter((v): v is string => !!v)),
  ];
  const requesters = new Map<string, { name: string; email: string }>();
  if (requesterIds.length) {
    const { data: ps, error: e } = await supabase.from("profiles").select("id, first_name, last_name, email").in("id", requesterIds);
    if (e) fail("requesters", e.code);
    for (const p of ps ?? []) requesters.set(p.id, { name: fullName(p.first_name, p.last_name), email: p.email });
  }

  return rows.map((r) => {
    const d = one(r.student_details)!;
    return {
      id: r.id,
      name: fullName(r.first_name, r.last_name),
      email: r.email,
      school: d.school ?? "",
      dateOfBirth: d.date_of_birth,
      parentName: d.signup_parent_name ?? "",
      parentEmail: d.signup_parent_email ?? "",
      signedUp: day(r.created_at),
      registeredBy: d.requested_by_parent ? (requesters.get(d.requested_by_parent) ?? null) : null,
    };
  });
}

export async function loadLinkRequests(): Promise<LinkRequestRow[]> {
  await requireStaff(MANAGERS);
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("parent_link_requests")
    .select(
      "id, created_at, parent:profiles!parent_id(first_name, last_name, email), child:profiles!student_id(first_name, last_name, student_details!profile_id(index_number, date_of_birth))",
    )
    .order("created_at");
  if (error) fail("link requests", error.code);
  type P = { first_name: string; last_name: string; email: string };
  type C = { first_name: string; last_name: string; student_details: Pick<Details, "index_number" | "date_of_birth"> | Pick<Details, "index_number" | "date_of_birth">[] | null };
  const rows = (data ?? []) as unknown as { id: string; created_at: string; parent: P | P[] | null; child: C | C[] | null }[];
  return rows.flatMap((r) => {
    const parent = one(r.parent);
    const child = one(r.child);
    if (!parent || !child) return [];
    const d = one(child.student_details);
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
}

/** Characters that would change a PostgREST `or`/`ilike` expression are dropped from the search text. */
function safeSearch(q: string): string {
  // Syntax characters of the `or` expression are dropped; LIKE wildcards and the escape character are escaped.
  return q
    .replace(/[,()*:"']/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 80)
    .replace(/[\\%_]/g, (m) => "\\" + m);
}

export async function loadAccountsPage(
  filters: AccountFilters,
  staffOnly: boolean,
): Promise<{ rows: AccountRow[]; total: number; page: number; pages: number }> {
  await requireStaff(MANAGERS);
  const supabase = await createClient();
  const page = Math.max(1, Math.floor(filters.page) || 1);
  let q = supabase
    .from("profiles")
    .select(
      "id, role, status, first_name, last_name, email, invite_sent_at, student_details!profile_id(index_number, signup_parent_email), parent_children!student_id(parent_id)",
      { count: "exact" },
    );
  if (staffOnly) q = q.in("role", STAFF_ROLES as AppRole[]);
  if (filters.role) q = q.eq("role", filters.role);
  if (filters.status) q = q.eq("status", filters.status);
  const s = safeSearch(filters.q);
  if (s) q = q.or(`first_name.ilike.%${s}%,last_name.ilike.%${s}%,email.ilike.%${s}%`);
  const from = (page - 1) * PAGE_SIZE;
  const { data, error, count } = await q
    .order("created_at", { ascending: false })
    .order("id")
    .range(from, from + PAGE_SIZE - 1);
  if (error) fail("accounts", error.code);

  const rows = ((data ?? []) as unknown as {
    id: string;
    role: AppRole;
    status: AccountStatus;
    first_name: string;
    last_name: string;
    email: string;
    invite_sent_at: string | null;
    student_details: Pick<Details, "index_number" | "signup_parent_email"> | Pick<Details, "index_number" | "signup_parent_email">[] | null;
    parent_children: unknown[] | null;
  }[]).map<AccountRow>((p) => {
    const d = one(p.student_details);
    return {
      id: p.id,
      role: p.role,
      status: p.status,
      firstName: p.first_name,
      lastName: p.last_name,
      email: p.email,
      inviteSentAt: p.invite_sent_at,
      indexNumber: d?.index_number ?? null,
      hasParent: (p.parent_children ?? []).length > 0,
      signupParentEmail: d?.signup_parent_email ?? null,
    };
  });
  const total = count ?? 0;
  return { rows, total, page, pages: Math.max(1, Math.ceil(total / PAGE_SIZE)) };
}
