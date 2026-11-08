"use client";

import { useEffect, useState, type FormEvent } from "react";

/** Edit the parent email typed at sign-up, for a pending or approved-but-unlinked student. */
export function EditParentEmailDialog({
  studentName,
  initial,
  busy,
  error,
  onSave,
  onClose,
}: {
  studentName: string;
  initial: string;
  busy: boolean;
  error: string | null;
  onSave: (email: string) => Promise<boolean>;
  onClose: () => void;
}) {
  const [email, setEmail] = useState(initial);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (await onSave(email)) onClose();
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4" onClick={onClose}>
      <form
        role="dialog"
        aria-modal="true"
        aria-label="Edit parent email"
        onSubmit={submit}
        onClick={(e) => e.stopPropagation()}
        className="w-full max-w-md rounded-lg bg-white p-6 shadow-xl"
      >
        <h2 className="text-base font-semibold text-slate-900">Edit parent email</h2>
        <p className="mt-1 text-sm text-slate-500">{studentName}</p>
        <label className="mt-3 block text-sm">
          Parent email
          <input
            type="email"
            required
            autoFocus
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
        </label>
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
            Save
          </button>
        </div>
      </form>
    </div>
  );
}
