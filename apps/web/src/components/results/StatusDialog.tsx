"use client";

import { useState } from "react";
import { ConfirmDialog } from "@/components/accounts/ConfirmDialog";
import { REASON_MAX, REASON_MIN } from "@/components/papers/ReasonDialog";
import type { SettableStatus } from "@/app/admin/results/[examId]/actions";

export type StatusTarget = { bookingId: string; name: string | null; indexNumber: string | null };

const CHOICES: { value: SettableStatus; label: string }[] = [
  { value: "absent", label: "Absent" },
  { value: "incomplete", label: "Incomplete" },
  { value: "disqualified", label: "Disqualified" },
  { value: "auto", label: "Back to automatic (from the register and the script)" },
];

/** "Set status" for one candidate: the new status and a reason of 3 to 300 characters. `onSubmit` gives back the refusal
 * in words, or null when it went through (the dialog is then closed by its owner). */
export function StatusDialog({
  target,
  published,
  busy,
  onSubmit,
  onCancel,
}: {
  target: StatusTarget;
  /** Results are published: this is a correction of one row. */
  published: boolean;
  busy: boolean;
  onSubmit: (status: SettableStatus, reason: string) => Promise<string | null>;
  onCancel: () => void;
}) {
  const [status, setStatus] = useState<SettableStatus>("absent");
  const [reason, setReason] = useState("");
  const [touched, setTouched] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const trimmed = reason.trim();
  const bad = trimmed.length < REASON_MIN || trimmed.length > REASON_MAX;
  const who = [target.name ?? "This candidate", target.indexNumber].filter(Boolean).join(", ");

  async function submit() {
    setTouched(true);
    if (bad) return;
    setError(null);
    setError(await onSubmit(status, trimmed));
  }

  return (
    <ConfirmDialog
      title="Set status"
      confirmLabel="Set status"
      tone="primary"
      busy={busy}
      onConfirm={() => void submit()}
      onCancel={() => {
        if (!busy) onCancel();
      }}
    >
      <div className="space-y-3">
        <p>{who}</p>
        {published && <p className="text-slate-600">These results are published. This corrects this candidate&apos;s row only, and families see the new version.</p>}
        <label className="block text-sm">
          <span className="font-medium text-slate-700">Status</span>
          <select value={status} onChange={(e) => setStatus(e.target.value as SettableStatus)} className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm">
            {CHOICES.map((c) => (
              <option key={c.value} value={c.value}>
                {c.label}
              </option>
            ))}
          </select>
        </label>
        <label className="block text-sm">
          <span className="font-medium text-slate-700">Reason</span>
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            rows={3}
            maxLength={REASON_MAX}
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm"
          />
          <span className="text-xs text-slate-500">3 to 300 characters. It goes into the audit log.</span>
        </label>
        {touched && bad && <p className="text-sm text-red-700">Give a reason of 3 to 300 characters.</p>}
        {error && (
          <p role="alert" className="text-sm text-red-700">
            {error}
          </p>
        )}
      </div>
    </ConfirmDialog>
  );
}
