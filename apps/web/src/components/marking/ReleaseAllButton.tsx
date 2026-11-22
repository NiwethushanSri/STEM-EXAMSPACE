"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import { releaseAllAlerts } from "@/app/marking/actions";

const QUIET = "min-h-11 rounded border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";

/** "Release all" for one exam, on its progress card: every changed-picture alert of the exam that can be released now
 * is released, with one reason. It needs only the exam, so it works when the alerts list itself cannot be loaded. The
 * database checks the lead or admin again and says how many were released. */
export function ReleaseAllButton({ examId, examTitle }: { examId: string; examTitle: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  const release = async (reason: string) => {
    setBusy(true);
    let r: Awaited<ReturnType<typeof releaseAllAlerts>>;
    try {
      r = await releaseAllAlerts(examId, reason);
    } catch {
      r = { ok: false, message: "Something went wrong. Try again." };
    } finally {
      setBusy(false);
    }
    if (!r.ok) return setError(r.message);
    setOpen(false);
    setDone(r.message);
    router.refresh();
  };

  return (
    <div className="flex flex-wrap items-center gap-3">
      <button
        type="button"
        className={QUIET}
        aria-label={`Release all for ${examTitle}`}
        onClick={() => {
          setError(null);
          setDone(null);
          setOpen(true);
        }}
      >
        Release all
      </button>
      <span aria-live="polite" className="text-sm text-green-800">
        {done}
      </span>
      {open && (
        <ReasonDialog title={`Release all for ${examTitle}`} confirmLabel="Release all" busy={busy} error={error} onCancel={() => setOpen(false)} onConfirm={release}>
          <p className="text-sm text-slate-700">Every changed picture of this exam that can be released now is released. The others stay open.</p>
        </ReasonDialog>
      )}
    </div>
  );
}
