"use client";

import { useState } from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { roleLabel, type AccountStatus, type AppRole } from "@stem/shared";
import { Badge, Card } from "@/components/AppShell";
import { actionsFor, type AccountFilters, type AccountRow, type Viewer } from "@/lib/account-rules";
import type { ActionResult } from "@/app/admin/accounts/actions";
import { ConfirmDialog } from "./ConfirmDialog";

type Kind = "suspend" | "reactivate" | "resend_invite" | "remove_staff" | "delete_account";
type Run = (key: string, fn: () => Promise<ActionResult>) => Promise<boolean>;

const ROLES: AppRole[] = ["owner", "admin", "teacher", "tutor", "corrector", "student", "parent"];
const STATUSES: AccountStatus[] = ["unconfirmed", "pending", "profile_incomplete", "active", "suspended"];
const STATUS_LABEL: Record<AccountStatus, string> = {
  unconfirmed: "Unconfirmed",
  pending: "Pending",
  profile_incomplete: "Profile incomplete",
  active: "Active",
  suspended: "Suspended",
};
const TONE: Record<AccountStatus, "green" | "amber" | "red" | "slate" | "blue"> = {
  active: "green",
  pending: "amber",
  profile_incomplete: "blue",
  unconfirmed: "slate",
  suspended: "red",
};

const btn = "rounded border border-slate-300 px-2.5 py-1 text-xs hover:bg-slate-50 disabled:opacity-60";

export function AccountsTable({
  title,
  rows,
  total,
  page,
  pages,
  filters,
  viewer,
  busyKey,
  run,
  act,
  onEditParent,
  roles = ROLES,
}: {
  title: string;
  rows: AccountRow[];
  total: number;
  page: number;
  pages: number;
  filters: AccountFilters;
  onEditParent: (row: AccountRow) => void;
  viewer: Viewer;
  busyKey: string | null;
  run: Run;
  act: (kind: Kind, id: string) => Promise<ActionResult>;
  roles?: AppRole[];
}) {
  const router = useRouter();
  const pathname = usePathname();
  const [query, setQuery] = useState(filters.q);
  const [seenQ, setSeenQ] = useState(filters.q);
  if (seenQ !== filters.q) {
    // The URL changed (back/forward, link): re-sync the box.
    setSeenQ(filters.q);
    setQuery(filters.q);
  }
  const [confirm, setConfirm] = useState<{ kind: "remove_staff" | "delete_account"; row: AccountRow } | null>(null);

  /** Filters live in the URL so the server applies them (the table never holds more than one page). */
  const hrefFor = (next: Partial<{ role: string; status: string; q: string; page: number }>) => {
    const p = new URLSearchParams();
    const merged = { role: filters.role ?? "", status: filters.status ?? "", q: filters.q, page: 1, ...next };
    if (merged.role) p.set("role", merged.role);
    if (merged.status) p.set("status", merged.status);
    if (merged.q) p.set("q", merged.q);
    if (merged.page > 1) p.set("page", String(merged.page));
    const qs = p.toString();
    return qs ? `${pathname}?${qs}` : pathname;
  };
  const shown = rows;

  const field = "rounded border border-slate-300 bg-white px-2 py-1.5 text-sm";

  return (
    <Card title={`${title} (${total})`}>
      <div className="mb-3 flex flex-wrap gap-3 text-sm">
        <label className="flex items-center gap-2">
          <span className="text-slate-600">Role</span>
          <select className={field} value={filters.role ?? "all"} onChange={(e) => router.replace(hrefFor({ role: e.target.value === "all" ? "" : e.target.value }))}>
            <option value="all">All roles</option>
            {roles.map((r) => (
              <option key={r} value={r}>
                {roleLabel(r)}
              </option>
            ))}
          </select>
        </label>
        <label className="flex items-center gap-2">
          <span className="text-slate-600">Status</span>
          <select className={field} value={filters.status ?? "all"} onChange={(e) => router.replace(hrefFor({ status: e.target.value === "all" ? "" : e.target.value }))}>
            <option value="all">All statuses</option>
            {STATUSES.map((s) => (
              <option key={s} value={s}>
                {STATUS_LABEL[s]}
              </option>
            ))}
          </select>
        </label>
        <form
          className="flex items-center gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            router.replace(hrefFor({ q: query.trim() }));
          }}
        >
          <label className="flex items-center gap-2">
            <span className="text-slate-600">Search accounts</span>
            <input
              type="search"
              className={`${field} w-64`}
              placeholder="Name or email, press Enter"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
          </label>
        </form>
      </div>

      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
            <tr>
              {["Name", "Email", "Role", "Status", "Index number", "Actions"].map((h) => (
                <th key={h} className="py-2 pr-4 font-medium">
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {shown.map((r) => {
              const a = actionsFor(viewer, r);
              const busy = busyKey === `acct:${r.id}`;
              const go = (kind: Kind) => run(`acct:${r.id}`, () => act(kind, r.id));
              return (
                <tr key={r.id} className="border-b border-slate-100 last:border-0">
                  <td className="py-2.5 pr-4 font-medium">{`${r.firstName} ${r.lastName}`.trim() || "—"}</td>
                  <td className="py-2.5 pr-4">{r.email}</td>
                  <td className="py-2.5 pr-4">{roleLabel(r.role)}</td>
                  <td className="py-2.5 pr-4">
                    <span className="flex flex-wrap items-center gap-1">
                      <Badge tone={TONE[r.status]}>{STATUS_LABEL[r.status]}</Badge>
                      {r.role !== "student" && r.role !== "owner" && r.inviteSentAt === null && <Badge tone="amber">Invite not sent</Badge>}
                    </span>
                  </td>
                  <td className="py-2.5 pr-4">{r.indexNumber ?? "—"}</td>
                  <td className="py-2.5 pr-4">
                    <span className="flex flex-wrap gap-2">
                      {a.toggleStatus && (
                        <button type="button" disabled={busy} className={btn} onClick={() => go(a.toggleStatus!)}>
                          {a.toggleStatus === "suspend" ? "Suspend" : "Reactivate"}
                        </button>
                      )}
                      {a.resendInvite && (
                        <button type="button" disabled={busy} className={btn} onClick={() => go("resend_invite")}>
                          Resend invite
                        </button>
                      )}
                      {a.resendParentInvite && (
                        <button type="button" disabled={busy} className={btn} onClick={() => go("resend_invite")}>
                          Resend parent invite
                        </button>
                      )}
                      {a.editParentEmail && (
                        <button type="button" disabled={busy} className={btn} onClick={() => onEditParent(r)}>
                          Edit parent email
                        </button>
                      )}
                      {a.removeStaff && (
                        <button type="button" disabled={busy} className={btn} onClick={() => setConfirm({ kind: "remove_staff", row: r })}>
                          Remove
                        </button>
                      )}
                      {a.deleteAccount && (
                        <button type="button" disabled={busy} className={btn} onClick={() => setConfirm({ kind: "delete_account", row: r })}>
                          Delete account
                        </button>
                      )}
                    </span>
                  </td>
                </tr>
              );
            })}
            {shown.length === 0 && (
              <tr>
                <td colSpan={6} className="py-4 text-slate-500">
                  No accounts match.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      <nav className="mt-3 flex items-center justify-between text-sm text-slate-600" aria-label="Pagination">
        <span>
          Page {page} of {pages}
        </span>
        <span className="flex gap-3">
          {page > 1 && (
            <Link href={hrefFor({ page: page - 1 })} className="text-blue-700 underline">
              Previous
            </Link>
          )}
          {page < pages && (
            <Link href={hrefFor({ page: page + 1 })} className="text-blue-700 underline">
              Next
            </Link>
          )}
        </span>
      </nav>

      {confirm && (
        <ConfirmDialog
          title={confirm.kind === "delete_account" ? "Delete account" : "Remove staff member"}
          confirmLabel={confirm.kind === "delete_account" ? "Delete account" : "Remove"}
          busy={busyKey === `acct:${confirm.row.id}`}
          onCancel={() => setConfirm(null)}
          onConfirm={async () => {
            const { kind, row } = confirm;
            await run(`acct:${row.id}`, () => act(kind, row.id));
            setConfirm(null);
          }}
        >
          {confirm.kind === "delete_account"
            ? "Permanently delete this account and its data?"
            : "Remove this staff member? Their account and sign-in are deleted."}
          <span className="mt-2 block text-slate-500">{confirm.row.email}</span>
        </ConfirmDialog>
      )}
    </Card>
  );
}
