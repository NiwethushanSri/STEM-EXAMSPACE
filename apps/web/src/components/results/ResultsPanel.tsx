"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { Card, Stat } from "@/components/AppShell";
import { BoundariesEditor } from "@/components/results/BoundariesEditor";
import { PublishBox, type RunAction } from "@/components/results/PublishBox";
import { ResultsTable } from "@/components/results/ResultsTable";
import { StatusDialog, type StatusTarget } from "@/components/results/StatusDialog";
import { exportResultsCsv, prepareResults, setResultStatus, type CsvResult, type ResultsActionResult } from "@/app/admin/results/[examId]/actions";
import { saveBlob } from "@/lib/download";
import { RESULT_STATUSES, STATUS_LABEL, type AdminResults } from "@/lib/results-admin";

const GENERIC = "Something went wrong. Please try again.";
const PRIMARY = "rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50";
const QUIET = "rounded border border-slate-300 px-4 py-2 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";

/** The batch totals: how many candidates in each status, the average and quartiles (once five are present), the 10%
 * bands and the count in each grade. */
function Totals({ r }: { r: AdminResults }) {
  const c = r.cohort;
  const top = Math.max(1, ...r.bands.map((b) => b.count));
  return (
    <Card title="Batch totals">
      <ul data-testid="results-counts" className="grid grid-cols-2 gap-3 sm:grid-cols-5">
        {RESULT_STATUSES.map((s) => (
          <li key={s} className="rounded border border-slate-200 px-3 py-2 text-sm text-slate-800">
            {STATUS_LABEL[s]}: <span className="font-semibold tabular-nums">{r.counts[s]}</span>
          </li>
        ))}
      </ul>

      {c ? (
        <div data-testid="results-cohort" className="mt-4 grid gap-3 sm:grid-cols-3">
          <Stat label="Average" value={c.average ?? "—"} />
          <Stat label="Lower quartile" value={c.lowerQuartile ?? "—"} />
          <Stat label="Upper quartile" value={c.upperQuartile ?? "—"} />
        </div>
      ) : (
        <p data-testid="results-cohort" className="mt-4 text-sm text-slate-700">
          Too few candidates to compare.
        </p>
      )}
      {r.maxTotal !== null && <p className="mt-2 text-xs text-slate-500">Marks are out of {r.maxTotal}.</p>}

      <h3 className="mt-5 text-sm font-semibold text-slate-900">Marks in bands of 10%</h3>
      <ul data-testid="results-bands" className="mt-2 space-y-1 text-sm">
        {r.bands.map((b) => (
          <li key={b.from} className="flex items-center gap-3">
            <span className="w-20 shrink-0 text-slate-700 tabular-nums">
              {b.from} to {b.to}%
            </span>
            <span className="h-2 flex-1 rounded bg-slate-100">
              <span className="block h-2 rounded bg-blue-600" style={{ width: `${(b.count / top) * 100}%` }} />
            </span>
            <span className="w-8 text-right tabular-nums text-slate-800">{b.count}</span>
          </li>
        ))}
      </ul>

      <h3 className="mt-5 text-sm font-semibold text-slate-900">Grades</h3>
      {r.grades.length === 0 ? (
        <p className="mt-1 text-sm text-slate-700">No boundaries are set, so no grades are given.</p>
      ) : (
        <div className="mt-1 overflow-x-auto">
          <table data-testid="results-grades" className="w-full max-w-md text-left text-sm">
            <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="py-2 pr-4 font-medium">Grade</th>
                <th className="py-2 pr-4 text-right font-medium">All</th>
                <th className="py-2 pr-4 text-right font-medium">Centre</th>
                <th className="py-2 text-right font-medium">Home</th>
              </tr>
            </thead>
            <tbody>
              {r.grades.map((g) => (
                <tr key={g.grade} className="border-b border-slate-100 last:border-0">
                  <td className="py-2 pr-4">{g.grade}</td>
                  <td className="py-2 pr-4 text-right tabular-nums">{g.all}</td>
                  <td className="py-2 pr-4 text-right tabular-nums">{g.centre}</td>
                  <td className="py-2 text-right tabular-nums">{g.home}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Card>
  );
}

/** An exam's results for the admin (results_get): Prepare results, the batch totals, the grade boundaries, the
 * candidates with Set status, the sign-off and publication, and Download CSV. After every action the page is read again,
 * so what it shows (and the version a sign-off sends) is what the database holds. */
export function ResultsPanel({ examId, results: r }: { examId: string; results: AdminResults }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [target, setTarget] = useState<StatusTarget | null>(null);

  const locked = r.state === "scheduled" || r.state === "published";

  /** Runs an action, then reads the page again. A success is shown as the notice; a refusal as the page's error, unless
   * the caller shows it itself (`quiet`: a dialog or an editor with its own place for it). */
  const run: RunAction = async (fn, opts) => {
    setBusy(true);
    setNotice(null);
    setError(null);
    const res = await fn().catch((): ResultsActionResult => ({ ok: false, message: GENERIC }));
    setBusy(false);
    if (res.ok) setNotice(res.message);
    else if (!opts?.quiet) setError(res.message);
    router.refresh();
    return res;
  };

  async function download() {
    setBusy(true);
    setNotice(null);
    setError(null);
    const res = await exportResultsCsv(examId).catch((): CsvResult => ({ ok: false, message: GENERIC }));
    setBusy(false);
    // The export was recorded by the call itself; the file is saved only now that it succeeded.
    if (res.ok) saveBlob(new Blob([res.csv], { type: "text/csv;charset=utf-8" }), res.filename);
    else setError(res.message);
  }

  async function submitStatus(status: Parameters<typeof setResultStatus>[2], reason: string): Promise<string | null> {
    if (!target) return GENERIC;
    const res = await run(() => setResultStatus(examId, target.bookingId, status, reason), { quiet: true });
    if (res.ok) {
      setTarget(null);
      return null;
    }
    return res.message;
  }

  return (
    <div className="space-y-5">
      <div aria-live="polite">
        {notice && (
          <div role="status" className="rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">
            {notice}
          </div>
        )}
        {error && (
          <div role="alert" className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">
            {error}
          </div>
        )}
      </div>

      {r.approvedAt === null && (
        <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">Marking is not approved for this exam, so results cannot be prepared.</div>
      )}
      {r.stale && (
        <div role="alert" data-testid="results-stale" className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          A script arrived or changed after the marking was approved. Withdraw the approval and approve it again first.
        </div>
      )}

      <Card title="Prepare results">
        <p className="text-sm text-slate-600">
          Prepares every candidate&apos;s total, percentage, grade and rank from the approved final marks. Preparing again keeps the statuses you set.
        </p>
        <div className="mt-3 flex flex-wrap gap-2">
          <button type="button" disabled={busy || locked} onClick={() => void run(() => prepareResults(examId))} className={PRIMARY}>
            Prepare results
          </button>
          <button type="button" disabled={busy || r.state === "none"} onClick={() => void download()} className={QUIET}>
            Download CSV
          </button>
        </div>
        {locked && <p className="mt-2 text-xs text-slate-500">The results are scheduled or published. They cannot be prepared again until cancelled or withdrawn.</p>}
      </Card>

      {r.state !== "none" && <Totals r={r} />}

      <BoundariesEditor
        key={JSON.stringify(r.boundaries)}
        examId={examId}
        boundaries={r.boundaries}
        maxTotal={r.maxTotal}
        locked={locked}
        prepared={r.state !== "none"}
        onDone={(res) => {
          if (res.ok) setNotice(res.message);
          router.refresh();
        }}
      />

      <Card title="Candidates">
        <ResultsTable rows={r.rows} missing={r.missing} more={r.more} busy={busy} onSetStatus={setTarget} />
      </Card>

      {r.state !== "none" && <PublishBox key={`${r.version}-${r.state}`} examId={examId} results={r} busy={busy} run={run} />}

      {target && (
        <StatusDialog target={target} published={r.state === "published"} busy={busy} onSubmit={submitStatus} onCancel={() => setTarget(null)} />
      )}
    </div>
  );
}
