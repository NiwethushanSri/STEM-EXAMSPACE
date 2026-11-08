import { Suspense } from "react";
import Link from "next/link";
import type { AccountStatus, AppRole } from "@stem/shared";
import { Card, Stat } from "@/components/AppShell";
import { loadAccountsPage, loadCounts, loadLinkRequests, loadPending } from "@/lib/accounts";
import type { AccountFilters } from "@/lib/account-rules";
import { requireStaff } from "@/lib/staff-gate";
import { AccountsManager } from "./AccountsManager";

const ROLE_VALUES: AppRole[] = ["owner", "admin", "teacher", "tutor", "corrector", "student", "parent"];
const STATUS_VALUES: AccountStatus[] = ["unconfirmed", "pending", "profile_incomplete", "active", "suspended"];

export type SearchParams = Promise<Record<string, string | string[] | undefined>>;

const first = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v) ?? "";

/** Reads and validates the URL filters (anything unknown is ignored). */
function parseFilters(raw: Record<string, string | string[] | undefined>): AccountFilters {
  const role = first(raw.role);
  const status = first(raw.status);
  const page = Number.parseInt(first(raw.page), 10);
  return {
    role: (ROLE_VALUES as string[]).includes(role) ? (role as AppRole) : null,
    status: (STATUS_VALUES as string[]).includes(status) ? (status as AccountStatus) : null,
    q: first(raw.q).slice(0, 80),
    page: Number.isFinite(page) && page > 0 ? page : 1,
  };
}

async function SectionBody({
  mode,
  roles,
  searchParams,
}: {
  mode: "all" | "staff";
  roles: readonly AppRole[];
  searchParams: SearchParams;
}) {
  const me = await requireStaff(roles);
  const filters = parseFilters(await searchParams);
  const [accounts, pending, links] = await Promise.all([
    loadAccountsPage(filters, mode === "staff"),
    mode === "all" ? loadPending() : Promise.resolve([]),
    mode === "all" ? loadLinkRequests() : Promise.resolve([]),
  ]);
  const viewer = { id: me.id, role: me.role === "owner" ? ("owner" as const) : ("admin" as const) };
  return <AccountsManager viewer={viewer} mode={mode} filters={filters} accounts={accounts} pending={pending} links={links} />;
}

async function OverviewBody({ accountsHref, roles }: { accountsHref: string; roles: readonly AppRole[] }) {
  await requireStaff(roles);
  const [counts, pending] = await Promise.all([loadCounts(), loadPending(5)]);
  return (
    <>
      <div className="grid gap-4 md:grid-cols-3">
        <Stat label="Accounts" value={counts.accounts} />
        <Stat label="Awaiting approval" value={counts.pending} />
        <Stat label="Parent link requests" value={counts.links} />
      </div>
      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <Card title="Pending student approvals">
          {pending.length === 0 ? (
            <p className="text-sm text-slate-500">No registrations are waiting for approval.</p>
          ) : (
            <ul className="divide-y divide-slate-100 text-sm">
              {pending.map((p) => (
                <li key={p.id} className="flex items-center justify-between py-2.5">
                  <span>
                    <span className="font-medium">{p.name}</span> · {p.school}
                  </span>
                  <Link href={accountsHref} className="text-blue-700 underline">
                    Review
                  </Link>
                </li>
              ))}
            </ul>
          )}
          {counts.pending > pending.length && (
            <Link href={accountsHref} className="mt-3 inline-block text-sm text-blue-700 underline">
              See all {counts.pending}
            </Link>
          )}
        </Card>
        <Card title="Exams, bookings and marking">
          <p className="text-sm text-slate-500">Coming in a later update.</p>
        </Card>
      </div>
    </>
  );
}

const loading = <p className="text-sm text-slate-500">Loading…</p>;

/** Live account management. `roles` is who may open the page (the loaders still re-check owner/admin). */
export function AccountsSection({
  mode,
  roles,
  searchParams,
}: {
  mode: "all" | "staff";
  roles: readonly AppRole[];
  searchParams: SearchParams;
}) {
  return (
    <Suspense fallback={loading}>
      <SectionBody mode={mode} roles={roles} searchParams={searchParams} />
    </Suspense>
  );
}

export function AccountsOverview({ accountsHref, roles }: { accountsHref: string; roles: readonly AppRole[] }) {
  return (
    <Suspense fallback={loading}>
      <OverviewBody accountsHref={accountsHref} roles={roles} />
    </Suspense>
  );
}
