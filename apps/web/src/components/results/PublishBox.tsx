"use client";

import { useState } from "react";
import { resultsMessageFor } from "@stem/shared";
import { Card } from "@/components/AppShell";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import { cancelPublication, signOffAndPublish, withdrawResults, type ResultsActionResult } from "@/app/admin/results/[examId]/actions";
import { formatLondon } from "@/lib/money";
import { publishAtCheck, stateText, type AdminResults } from "@/lib/results-admin";

const FIELD = "rounded border border-slate-300 px-3 py-2 text-sm";
const PRIMARY = "rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50";
const QUIET = "rounded border border-slate-300 px-4 py-2 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";

export type RunAction = (fn: () => Promise<ResultsActionResult>, opts?: { quiet?: boolean }) => Promise<ResultsActionResult>;

/** Sign-off and publication. Prepared (or withdrawn and prepared again): "I have checked these totals" must be ticked
 * before "Sign off and publish", with "Publish at" in UK time (empty publishes now). Scheduled: "Cancel the scheduled
 * publication". Published: "Withdraw results" (a reason). The sign-off sends the version the page showed; the page is
 * keyed by that version, so the tick is gone whenever it changes. */
export function PublishBox({ examId, results: r, busy, run }: { examId: string; results: AdminResults; busy: boolean; run: RunAction }) {
  const [checked, setChecked] = useState(false);
  const [date, setDate] = useState("");
  const [time, setTime] = useState("");
  const [problem, setProblem] = useState<string | null>(null);
  const [withdrawing, setWithdrawing] = useState(false);
  const [withdrawError, setWithdrawError] = useState<string | null>(null);

  function signOff() {
    const when = publishAtCheck(date, time, Date.now());
    if (!when.ok) return setProblem(when.message);
    setProblem(null);
    void run(() => signOffAndPublish(examId, r.version, date, time));
  }

  async function withdraw(reason: string) {
    const res = await run(() => withdrawResults(examId, reason), { quiet: true });
    if (res.ok) setWithdrawing(false);
    else setWithdrawError(res.message);
  }

  return (
    <Card title="Publication">
      <p data-testid="results-state" className="text-sm font-medium text-slate-900">
        {stateText(r)}
      </p>

      {r.publishFailedAt && r.state === "prepared" && (
        <div role="alert" className="mt-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          The scheduled publication on {formatLondon(r.publishFailedAt)} (UK time) did not go ahead. {resultsMessageFor(r.publishFailedReason)}
        </div>
      )}
      {r.state === "withdrawn" && (
        <p className="mt-2 text-sm text-slate-700">
          Withdrawn{r.withdrawnAt ? ` on ${formatLondon(r.withdrawnAt)} (UK time)` : ""}
          {r.withdrawReason ? `. Reason: ${r.withdrawReason}` : ""}. Prepare the results again before publishing them.
        </p>
      )}

      {(r.state === "prepared" || r.state === "withdrawn") && (
        <div className="mt-4 space-y-3">
          <label className="flex items-start gap-2 text-sm text-slate-800">
            <input type="checkbox" checked={checked} disabled={busy} onChange={(e) => setChecked(e.target.checked)} className="mt-0.5" />
            <span>I have checked these totals</span>
          </label>
          <fieldset className="space-y-1">
            <legend className="text-sm font-medium text-slate-700">Publish at</legend>
            <div className="flex flex-wrap gap-3">
              <input type="date" value={date} disabled={busy} onChange={(e) => setDate(e.target.value)} aria-label="Publish at date" className={FIELD} />
              <input type="time" value={time} disabled={busy} onChange={(e) => setTime(e.target.value)} aria-label="Publish at time" className={FIELD} />
            </div>
            <p className="text-xs text-slate-500">UK time (Europe/London). Leave both empty to publish now. Up to 30 days ahead.</p>
          </fieldset>
          {problem && (
            <p role="alert" className="text-sm text-red-700">
              {problem}
            </p>
          )}
          <button type="button" disabled={busy || !checked} onClick={signOff} className={PRIMARY}>
            Sign off and publish
          </button>
        </div>
      )}

      {r.state === "scheduled" && (
        <div className="mt-4">
          <button type="button" disabled={busy} onClick={() => void run(() => cancelPublication(examId))} className={QUIET}>
            Cancel the scheduled publication
          </button>
        </div>
      )}

      {r.state === "published" && (
        <div className="mt-4 space-y-2">
          <p className="text-sm text-slate-600">Families can see these results. A status change now corrects that one candidate&apos;s row.</p>
          <button
            type="button"
            disabled={busy}
            onClick={() => {
              setWithdrawError(null);
              setWithdrawing(true);
            }}
            className={QUIET}
          >
            Withdraw results
          </button>
        </div>
      )}

      {withdrawing && (
        <ReasonDialog
          title="Withdraw results?"
          confirmLabel="Withdraw results"
          tone="danger"
          busy={busy}
          error={withdrawError}
          onConfirm={(reason) => void withdraw(reason)}
          onCancel={() => {
            if (!busy) setWithdrawing(false);
          }}
        >
          <p className="text-sm text-slate-700">Families can no longer see these results. You can prepare and publish them again.</p>
        </ReasonDialog>
      )}
    </Card>
  );
}
