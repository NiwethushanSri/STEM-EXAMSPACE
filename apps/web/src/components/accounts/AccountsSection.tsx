import { Suspense } from "react";
import { redirect } from "next/navigation";
import { Card, Stat } from "@/components/AppShell";
import { loadAccounts } from "@/lib/accounts";
import { getSessionProfile } from "@/lib/supabase/server";
import { AccountsManager } from "./AccountsManager";
import Link from "next/link";

async function viewer() {
  const me = await getSessionProfile();
  if (!me || (me.role !== "owner" && me.role !== "admin")) redirect("/login");
  return { id: me.id, role: me.role } as const;
}

/** Live account management (server component: reads with the caller's session, RLS applies). */
async function SectionBody({ mode }: { mode: "all" | "staff" }) {
  const [v, data] = await Promise.all([viewer(), loadAccounts()]);
  return <AccountsManager viewer={v} mode={mode} {...data} />;
}

/** Dashboard body shared by /admin and /owner: real counts and the first pending registrations. */
async function OverviewBody({ accountsHref }: { accountsHref: string }) {
  await viewer();
  const { accounts, pending, links } = await loadAccounts();
  return (
    <>
      <div className="grid gap-4 md:grid-cols-3">
        <Stat label="Accounts" value={accounts.length} />
        <Stat label="Awaiting approval" value={pending.length} />
        <Stat label="Parent link requests" value={links.length} />
      </div>
      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <Card title="Pending student approvals">
          {pending.length === 0 ? (
            <p className="text-sm text-slate-500">No registrations are waiting for approval.</p>
          ) : (
            <ul className="divide-y divide-slate-100 text-sm">
              {pending.slice(0, 5).map((p) => (
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
          {pending.length > 5 && (
            <Link href={accountsHref} className="mt-3 inline-block text-sm text-blue-700 underline">
              See all {pending.length}
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

export function AccountsSection({ mode }: { mode: "all" | "staff" }) {
  return (
    <Suspense fallback={loading}>
      <SectionBody mode={mode} />
    </Suspense>
  );
}

export function AccountsOverview({ accountsHref }: { accountsHref: string }) {
  return (
    <Suspense fallback={loading}>
      <OverviewBody accountsHref={accountsHref} />
    </Suspense>
  );
}
