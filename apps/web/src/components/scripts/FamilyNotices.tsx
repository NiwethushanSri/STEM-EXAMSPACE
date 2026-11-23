"use client";

import { useId, useState } from "react";
import { useRouter } from "next/navigation";
import { skipFamilyNoticesAction } from "@/app/admin/scripts/actions";
import { SKIP_TEXT, acceptReasonProblem, familyNoticesLine } from "@/lib/home-drafts";

const BUTTON = "rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50";

/** The family emails still waiting to be sent, with "Do not send them" (a reason is needed and kept). */
export function FamilyNotices({ count }: { count: number }) {
  const router = useRouter();
  const id = useId();
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);

  async function skip() {
    const problem = acceptReasonProblem(reason);
    if (problem) return setNote({ ok: false, text: problem });
    setBusy(true);
    setNote(null);
    const r = await skipFamilyNoticesAction(reason).catch(() => ({ ok: false, message: "Something went wrong. Please try again." }));
    setBusy(false);
    setNote({ ok: r.ok, text: r.message });
    if (r.ok) router.refresh();
  }

  return (
    <div data-testid="family-notices" className="space-y-2">
      <p className="text-sm text-amber-900">{familyNoticesLine(count)}</p>
      <div className="flex flex-wrap items-end gap-2">
        <label htmlFor={id} className="flex min-w-64 flex-1 flex-col gap-1 text-sm text-slate-700">
          {SKIP_TEXT.reason}
          <input id={id} type="text" value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)}
            className="rounded border border-slate-300 bg-white px-2 py-1.5" />
        </label>
        <button type="button" className={BUTTON} disabled={busy} onClick={() => void skip()}>
          {SKIP_TEXT.button}
        </button>
      </div>
      {note && (
        <p role={note.ok ? "status" : "alert"} className={`text-sm ${note.ok ? "text-green-800" : "text-red-700"}`}>
          {note.text}
        </p>
      )}
    </div>
  );
}
