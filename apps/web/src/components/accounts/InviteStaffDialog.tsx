"use client";

import { useEffect, useState, type FormEvent } from "react";
import { roleLabel, type AppRole } from "@stem/shared";
import { invitableRoles, type Viewer } from "@/lib/account-rules";

export type InviteInput = { email: string; firstName: string; lastName: string; role: AppRole };

export function InviteStaffDialog({
  viewer,
  busy,
  error,
  onInvite,
  onClose,
}: {
  viewer: Viewer;
  busy: boolean;
  error: string | null;
  onInvite: (input: InviteInput) => Promise<boolean>;
  onClose: () => void;
}) {
  const roles = invitableRoles(viewer.role);
  const [email, setEmail] = useState("");
  const [firstName, setFirstName] = useState("");
  const [lastName, setLastName] = useState("");
  const [role, setRole] = useState<AppRole>(roles[0]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (await onInvite({ email, firstName, lastName, role })) onClose();
  }

  const field = "mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm";
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4" onClick={onClose}>
      <form
        role="dialog"
        aria-modal="true"
        aria-label="Invite staff"
        onSubmit={submit}
        onClick={(e) => e.stopPropagation()}
        className="w-full max-w-md rounded-lg bg-white p-6 shadow-xl"
      >
        <h2 className="text-base font-semibold text-slate-900">Invite staff</h2>
        <div className="mt-3 space-y-3 text-sm">
          <label className="block">
            Email
            <input type="email" required autoFocus className={field} value={email} onChange={(e) => setEmail(e.target.value)} />
          </label>
          <div className="grid grid-cols-2 gap-3">
            <label className="block">
              First name
              <input required className={field} value={firstName} onChange={(e) => setFirstName(e.target.value)} />
            </label>
            <label className="block">
              Last name
              <input required className={field} value={lastName} onChange={(e) => setLastName(e.target.value)} />
            </label>
          </div>
          <label className="block">
            Role
            <select className={field} value={role} onChange={(e) => setRole(e.target.value as AppRole)}>
              {roles.map((r) => (
                <option key={r} value={r}>
                  {roleLabel(r)}
                </option>
              ))}
            </select>
          </label>
        </div>
        {error && (
          <p role="alert" className="mt-3 rounded bg-red-50 p-2 text-sm text-red-800">
            {error}
          </p>
        )}
        <div className="mt-5 flex justify-end gap-2">
          <button type="button" onClick={onClose} className="rounded border border-slate-300 px-4 py-2 text-sm hover:bg-slate-50">
            Cancel
          </button>
          <button
            type="submit"
            disabled={busy}
            className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60"
          >
            Send invitation
          </button>
        </div>
      </form>
    </div>
  );
}
