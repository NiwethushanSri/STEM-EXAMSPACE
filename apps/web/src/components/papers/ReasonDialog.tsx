"use client";

import { useState, type ReactNode } from "react";
import { ConfirmDialog } from "@/components/accounts/ConfirmDialog";

export const REASON_MIN = 3;
export const REASON_MAX = 300;

/** A confirm dialog that asks for a reason (3 to 300 characters) before it lets the action go ahead. */
export function ReasonDialog({
  title,
  confirmLabel,
  tone = "primary",
  busy,
  error,
  children,
  onConfirm,
  onCancel,
}: {
  title: string;
  confirmLabel: string;
  tone?: "danger" | "primary";
  busy: boolean;
  error: string | null;
  children?: ReactNode;
  onConfirm: (reason: string) => void;
  onCancel: () => void;
}) {
  const [reason, setReason] = useState("");
  const [touched, setTouched] = useState(false);
  const trimmed = reason.trim();
  const bad = trimmed.length < REASON_MIN || trimmed.length > REASON_MAX;
  return (
    <ConfirmDialog
      title={title}
      confirmLabel={confirmLabel}
      tone={tone}
      busy={busy}
      onConfirm={() => {
        setTouched(true);
        if (!bad) onConfirm(trimmed);
      }}
      onCancel={onCancel}
    >
      <div className="space-y-3">
        {children}
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
