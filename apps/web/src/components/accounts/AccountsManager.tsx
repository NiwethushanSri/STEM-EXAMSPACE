"use client";

import { useState, useTransition } from "react";
import { messageFor } from "@stem/shared";
import {
  accountAction,
  approveAction,
  clearStuckInviteAction,
  inviteAction,
  linkRequestAction,
  rejectAction,
  type ActionResult,
} from "@/app/admin/accounts/actions";
import type { AccountRow, LinkRequestRow, PendingRow, Viewer } from "@/lib/account-rules";
import { STAFF_ROLES } from "@/lib/account-rules";
import { AccountsTable } from "./AccountsTable";
import { InviteStaffDialog, type InviteInput } from "./InviteStaffDialog";
import { LinkRequestsTable, PendingTable } from "./PendingTable";

type Notice = { ok: boolean; message: string; warning?: string };

/**
 * The interactive account screens. `mode="staff"` (owner Staff page) shows only staff accounts and the
 * invite controls; `mode="all"` adds pending approvals and parent link requests.
 */
export function AccountsManager({
  viewer,
  accounts,
  pending,
  links,
  mode,
}: {
  viewer: Viewer;
  accounts: AccountRow[];
  pending: PendingRow[];
  links: LinkRequestRow[];
  mode: "all" | "staff";
}) {
  const [notice, setNotice] = useState<Notice | null>(null);
  const [busyKey, setBusyKey] = useState<string | null>(null);
  const [inviting, setInviting] = useState(false);
  const [, startTransition] = useTransition();

  /** Runs a server action, shows its outcome and resolves true on success. The action revalidates the page. */
  function run(key: string, fn: () => Promise<ActionResult>): Promise<boolean> {
    setBusyKey(key);
    setNotice(null);
    return new Promise<boolean>((resolve) => {
      startTransition(async () => {
        let result: ActionResult;
        try {
          result = await fn();
        } catch {
          result = { ok: false, code: "internal", message: messageFor("internal") };
        }
        if (result.ok) setNotice({ ok: true, message: result.message, warning: result.warning });
        else setNotice({ ok: false, message: result.code === "conflict" ? messageFor("conflict") : result.message });
        setBusyKey(null);
        resolve(result.ok);
      });
    });
  }

  const visible = mode === "staff" ? accounts.filter((a) => STAFF_ROLES.includes(a.role)) : accounts;
  const roles = mode === "staff" ? STAFF_ROLES.slice() : undefined;

  return (
    <div className="space-y-6">
      {notice && !(inviting && !notice.ok) &&
        (notice.ok ? (
          <div role="status" className="rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">
            <p>{notice.message}</p>
            {notice.warning && <p className="mt-1 text-amber-800">{notice.warning}</p>}
          </div>
        ) : (
          <div role="alert" className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">
            {notice.message}
          </div>
        ))}

      <div className="flex justify-end">
        <button
          type="button"
          onClick={() => {
            setNotice(null);
            setInviting(true);
          }}
          className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
        >
          Invite staff
        </button>
      </div>

      {mode === "all" && (
        <>
          <PendingTable
            rows={pending}
            busyKey={busyKey}
            run={run}
            approve={approveAction}
            reject={rejectAction}
          />
          <LinkRequestsTable rows={links} busyKey={busyKey} run={run} decide={linkRequestAction} />
        </>
      )}

      <AccountsTable
        title={mode === "staff" ? "Staff accounts" : "All accounts"}
        rows={visible}
        viewer={viewer}
        busyKey={busyKey}
        run={run}
        act={accountAction}
        roles={roles}
      />

      <details className="rounded-lg border border-slate-200 bg-white p-4 text-sm">
        <summary className="cursor-pointer font-medium text-slate-700">Troubleshooting</summary>
        <ClearStuckInvite busy={busyKey === "clear"} onClear={(email) => run("clear", () => clearStuckInviteAction(email))} />
      </details>

      {inviting && (
        <InviteStaffDialog
          viewer={viewer}
          busy={busyKey === "invite"}
          error={notice && !notice.ok ? notice.message : null}
          onClose={() => setInviting(false)}
          onInvite={(input: InviteInput) => run("invite", () => inviteAction(input))}
        />
      )}
    </div>
  );
}

function ClearStuckInvite({ busy, onClear }: { busy: boolean; onClear: (email: string) => Promise<boolean> }) {
  const [email, setEmail] = useState("");
  return (
    <form
      className="mt-3 flex flex-wrap items-end gap-3"
      onSubmit={async (e) => {
        e.preventDefault();
        if (await onClear(email)) setEmail("");
      }}
    >
      <label className="block">
        <span className="text-slate-600">Clear stuck invite for email</span>
        <input
          type="email"
          required
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          className="mt-1 block w-72 rounded border border-slate-300 px-3 py-2"
        />
      </label>
      <button
        type="submit"
        disabled={busy}
        className="rounded border border-slate-300 px-4 py-2 hover:bg-slate-50 disabled:opacity-60"
      >
        Clear invite
      </button>
    </form>
  );
}
