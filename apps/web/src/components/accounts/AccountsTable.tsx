"use client";

import { useMemo, useState } from "react";
import { roleLabel, type AccountStatus, type AppRole } from "@stem/shared";
import { Badge, Card } from "@/components/AppShell";
import { actionsFor, type AccountRow, type Viewer } from "@/lib/account-rules";
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
  viewer,
  busyKey,
  run,
  act,
  roles = ROLES,
}: {
  title: string;
  rows: AccountRow[];
  viewer: Viewer;
  busyKey: string | null;
  run: Run;
  act: (kind: Kind, id: string) => Promise<ActionResult>;
  roles?: AppRole[];
}) {
  const [role, setRole] = useState<AppRole | "all">("all");
  const [status, setStatus] = useState<AccountStatus | "all">("all");
  const [query, setQuery] = useState("");
  const [confirm, setConfirm] = useState<{ kind: "remove_staff" | "delete_account"; row: AccountRow } | null>(null);

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();
    return rows.filter(
      (r) =>
        (role === "all" || r.role === role) &&
        (status === "all" || r.status === status) &&
        (!q || `${r.firstName} ${r.lastName}`.toLowerCase().includes(q) || r.email.toLowerCase().includes(q)),
    );
  }, [rows, role, status, query]);

  const field = "rounded border border-slate-300 bg-white px-2 py-1.5 text-sm";

  return (
    <Card title={`${title} (${shown.length})`}>
      <div className="mb-3 flex flex-wrap gap-3 text-sm">
        <label className="flex items-center gap-2">
          <span className="text-slate-600">Role</span>
          <select className={field} value={role} onChange={(e) => setRole(e.target.value as AppRole | "all")}>
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
          <select className={field} value={status} onChange={(e) => setStatus(e.target.value as AccountStatus | "all")}>
            <option value="all">All statuses</option>
            {STATUSES.map((s) => (
              <option key={s} value={s}>
                {STATUS_LABEL[s]}
              </option>
            ))}
          </select>
        </label>
        <label className="flex items-center gap-2">
          <span className="text-slate-600">Search accounts</span>
          <input
            type="search"
            className={`${field} w-64`}
            placeholder="Name or email"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </label>
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
                      {r.role !== "student" && r.inviteSentAt === null && <Badge tone="amber">Invite not sent</Badge>}
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
