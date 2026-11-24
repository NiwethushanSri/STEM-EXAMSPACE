"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Card } from "@/components/AppShell";
import { ConfirmDialog } from "@/components/accounts/ConfirmDialog";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import { approveMarking, withdrawApproval, type ApprovalActionResult } from "@/app/admin/marking/[examId]/approval/actions";
import { checksOffLine } from "@/lib/exam-marking";
import { blockText, checkLines, figureLines, noteProblem, scriptLines, STALE_TEXT, type Approval } from "@/lib/marking-approval";
import { formatLondon } from "@/lib/money";

const GENERIC = "Something went wrong. Please try again.";
const PRIMARY = "rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50";
const QUIET = "rounded border border-slate-300 px-4 py-2 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";

/** An exam's approval page (marking_approval_get): its scripts, what still blocks approval, the checks in force (and,
 * when any is turned off, who turned them off, when and why), what the checks found, and "Approve this exam's marking"
 * with an optional note; once approved, who approved it and when, with "Withdraw approval" (a reason). A script that
 * arrived after the approval is flagged. Counts and staff names only: nothing of a candidate. */
export function ApprovalPanel({ examId, approval }: { examId: string; approval: Approval }) {
  const router = useRouter();
  const [dialog, setDialog] = useState<"approve" | "withdraw" | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const a = approval;
  const approved = a.approvedAt !== null;

  function open(d: "approve" | "withdraw") {
    setError(null);
    setNotice(null);
    setNote("");
    setDialog(d);
  }

  /** Runs an action; a success closes the dialog and refreshes the page, a refusal is shown in the dialog (and the page
   * is refreshed, so what blocks approval is up to date). */
  async function run(action: () => Promise<ApprovalActionResult>) {
    setBusy(true);
    const res = await action().catch((): ApprovalActionResult => ({ ok: false, message: GENERIC }));
    setBusy(false);
    if (res.ok) {
      setDialog(null);
      setNotice(res.message);
    } else {
      setError(res.message);
    }
    router.refresh();
  }

  function approve() {
    const problem = noteProblem(note);
    if (problem) return setError(problem);
    void run(() => approveMarking(examId, note.trim()));
  }

  return (
    <div className="space-y-5">
      {notice && (
        <div role="status" className="rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">
          {notice}
        </div>
      )}
      {a.stale && (
        <div role="alert" data-testid="approval-stale" className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          {STALE_TEXT}
        </div>
      )}

      <Card title="Scripts">
        <ul data-testid="approval-scripts" className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          {scriptLines(a).map((line) => (
            <li key={line} className="rounded border border-slate-200 px-3 py-2 text-sm text-slate-800">
              {line}
            </li>
          ))}
        </ul>
      </Card>

      <Card title="What still blocks approval">
        {!a.opened ? (
          <p className="text-sm text-slate-700">Marking has not opened for this exam.</p>
        ) : a.blocks.length === 0 ? (
          <p className="text-sm text-slate-700">Nothing blocks approval.</p>
        ) : (
          <ul data-testid="approval-blocks" className="list-inside list-disc space-y-1 text-sm text-slate-800">
            {a.blocks.map((b) => (
              <li key={b.code}>{blockText(b)}</li>
            ))}
          </ul>
        )}
      </Card>

      <Card title="Checks">
        <ul className="space-y-1 text-sm text-slate-800">
          {checkLines(a.checks).map((line) => (
            <li key={line}>{line}</li>
          ))}
          <li>Lead marker: {a.leadName ?? "none"}.</li>
        </ul>
        {a.checks.off && (
          <div data-testid="checks-turned-off" className="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
            <p className="font-semibold">Checks turned off</p>
            <p className="mt-1">{checksOffLine(a.checks.off)}</p>
          </div>
        )}
      </Card>

      <Card title="What the checks found">
        <ul data-testid="approval-figures" className="space-y-1 text-sm text-slate-800">
          {figureLines(a.figures).map((line) => (
            <li key={line}>{line}</li>
          ))}
        </ul>
      </Card>

      <Card title="Approval">
        {approved ? (
          <div className="space-y-3">
            <p data-testid="approved-by" className="text-sm text-slate-800">
              Approved by {a.approvedByName ?? "an admin"} on {formatLondon(a.approvedAt ?? "")} (UK time).
            </p>
            <p className="text-sm text-slate-600">Marking is closed, and nothing about it can change until the approval is withdrawn.</p>
            <button type="button" disabled={busy} onClick={() => open("withdraw")} className={QUIET}>
              Withdraw approval
            </button>
          </div>
        ) : (
          <div className="space-y-3">
            <p className="text-sm text-slate-600">
              Approving closes marking for this exam. Nothing about its marking can change until an admin withdraws the approval.
            </p>
            {!a.canApprove && <p className="text-sm text-slate-600">This exam&apos;s marking can be approved once nothing above blocks it.</p>}
            <button type="button" disabled={busy || !a.canApprove} onClick={() => open("approve")} className={PRIMARY}>
              Approve this exam&apos;s marking
            </button>
          </div>
        )}
      </Card>

      {dialog === "approve" && (
        <ConfirmDialog
          title="Approve this exam's marking?"
          confirmLabel="Approve this exam's marking"
          tone="primary"
          busy={busy}
          onConfirm={approve}
          onCancel={() => {
            if (!busy) setDialog(null);
          }}
        >
          <div className="space-y-3">
            <p>Marking closes, and nothing about it can change until an admin withdraws the approval.</p>
            <label className="block text-sm">
              <span className="font-medium text-slate-700">Note (optional)</span>
              <textarea
                value={note}
                onChange={(e) => setNote(e.target.value)}
                rows={3}
                maxLength={300}
                className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm"
              />
              <span className="text-xs text-slate-500">Up to 300 characters. It goes into the audit log.</span>
            </label>
            {error && (
              <p role="alert" className="text-sm text-red-700">
                {error}
              </p>
            )}
          </div>
        </ConfirmDialog>
      )}
      {dialog === "withdraw" && (
        <ReasonDialog
          title="Withdraw approval?"
          confirmLabel="Withdraw approval"
          tone="danger"
          busy={busy}
          error={error}
          onConfirm={(reason) => void run(() => withdrawApproval(examId, reason))}
          onCancel={() => setDialog(null)}
        >
          <p className="text-sm text-slate-700">Marking stays closed until an admin reopens it.</p>
        </ReasonDialog>
      )}
    </div>
  );
}
