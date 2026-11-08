"use client";

import { useState } from "react";
import { Badge, Card } from "@/components/AppShell";
import { ageFrom, type LinkRequestRow, type PendingRow } from "@/lib/account-rules";
import type { ActionResult } from "@/app/admin/accounts/actions";
import { ConfirmDialog } from "./ConfirmDialog";

type Run = (key: string, fn: () => Promise<ActionResult>) => Promise<boolean>;

export function PendingTable({
  rows,
  busyKey,
  run,
  approve,
  reject,
}: {
  rows: PendingRow[];
  busyKey: string | null;
  run: Run;
  approve: (id: string) => Promise<ActionResult>;
  reject: (id: string) => Promise<ActionResult>;
}) {
  const [confirming, setConfirming] = useState<PendingRow | null>(null);
  return (
    <Card title={`Pending approvals (${rows.length})`}>
      {rows.length === 0 ? (
        <p className="text-sm text-slate-500">No registrations are waiting for approval.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
              <tr>
                {["Student", "School", "Date of birth", "Parent", "Signed up", "Actions"].map((h) => (
                  <th key={h} className="py-2 pr-4 font-medium">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((p) => {
                const age = ageFrom(p.dateOfBirth);
                const busy = busyKey === `pending:${p.id}`;
                return (
                  <tr key={p.id} className="border-b border-slate-100 align-top last:border-0">
                    <td className="py-2.5 pr-4">
                      <div className="font-medium">{p.name}</div>
                      <div className="text-slate-500">{p.email}</div>
                      {p.registeredBy && (
                        <div className="mt-1">
                          <Badge tone="amber">
                            Registered by {p.registeredBy.name} ({p.registeredBy.email})
                          </Badge>
                        </div>
                      )}
                    </td>
                    <td className="py-2.5 pr-4">{p.school}</td>
                    <td className="py-2.5 pr-4">
                      {p.dateOfBirth ?? "—"}
                      {age !== null && <span className="text-slate-500"> (age {age})</span>}
                    </td>
                    <td className="py-2.5 pr-4">
                      <div>{p.parentName}</div>
                      <div className="text-slate-500">{p.parentEmail}</div>
                    </td>
                    <td className="py-2.5 pr-4">{p.signedUp}</td>
                    <td className="py-2.5 pr-4">
                      <span className="flex gap-2">
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() => run(`pending:${p.id}`, () => approve(p.id))}
                          className="rounded bg-blue-600 px-3 py-1 text-xs text-white hover:bg-blue-700 disabled:opacity-60"
                        >
                          Approve
                        </button>
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() => setConfirming(p)}
                          className="rounded border border-slate-300 px-3 py-1 text-xs hover:bg-slate-50 disabled:opacity-60"
                        >
                          Reject
                        </button>
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      {confirming && (
        <ConfirmDialog
          title="Reject registration"
          confirmLabel="Reject registration"
          busy={busyKey === `pending:${confirming.id}`}
          onCancel={() => setConfirming(null)}
          onConfirm={async () => {
            const target = confirming;
            await run(`pending:${target.id}`, () => reject(target.id));
            setConfirming(null);
          }}
        >
          Reject and delete this registration? This cannot be undone.
          <span className="mt-2 block text-slate-500">{confirming.email}</span>
        </ConfirmDialog>
      )}
    </Card>
  );
}

export function LinkRequestsTable({
  rows,
  busyKey,
  run,
  decide,
}: {
  rows: LinkRequestRow[];
  busyKey: string | null;
  run: Run;
  decide: (id: string, decision: "approve" | "reject") => Promise<ActionResult>;
}) {
  return (
    <Card title={`Parent link requests (${rows.length})`}>
      {rows.length === 0 ? (
        <p className="text-sm text-slate-500">No parent link requests.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
              <tr>
                {["Parent", "Child", "Index number", "Date of birth", "Requested", "Actions"].map((h) => (
                  <th key={h} className="py-2 pr-4 font-medium">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => {
                const busy = busyKey === `link:${r.id}`;
                return (
                  <tr key={r.id} className="border-b border-slate-100 last:border-0">
                    <td className="py-2.5 pr-4">
                      <div className="font-medium">{r.parentName}</div>
                      <div className="text-slate-500">{r.parentEmail}</div>
                    </td>
                    <td className="py-2.5 pr-4">{r.childName}</td>
                    <td className="py-2.5 pr-4">{r.childIndex ?? "—"}</td>
                    <td className="py-2.5 pr-4">{r.childDob ?? "—"}</td>
                    <td className="py-2.5 pr-4">{r.requested}</td>
                    <td className="py-2.5 pr-4">
                      <span className="flex gap-2">
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() => run(`link:${r.id}`, () => decide(r.id, "approve"))}
                          className="rounded bg-blue-600 px-3 py-1 text-xs text-white hover:bg-blue-700 disabled:opacity-60"
                        >
                          Approve
                        </button>
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() => run(`link:${r.id}`, () => decide(r.id, "reject"))}
                          className="rounded border border-slate-300 px-3 py-1 text-xs hover:bg-slate-50 disabled:opacity-60"
                        >
                          Reject
                        </button>
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}
