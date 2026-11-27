"use client";

import { Badge } from "@/components/AppShell";
import { ordinal, SITTING_LABEL, STATUS_LABEL, type MissingCandidate, type ResultRow, type ResultStatus } from "@/lib/results-admin";

const QUIET = "rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";

const TONE: Record<ResultStatus, "green" | "slate" | "amber" | "red"> = {
  present: "green",
  absent: "slate",
  withdrawn: "slate",
  incomplete: "amber",
  disqualified: "red",
};

const show = (n: number | null, unit = "") => (n === null ? "—" : `${n}${unit}`);

/** The candidates: name, index number, mode, status, total, percentage, grade and rank, each with "Set status".
 * Candidates who were at the centre but have no script are listed above it, as the missing list. The server caps the
 * rows at 2,000; `more` says so. */
export function ResultsTable({
  rows,
  missing,
  more,
  busy,
  onSetStatus,
}: {
  rows: ResultRow[];
  missing: MissingCandidate[];
  more: boolean;
  busy: boolean;
  onSetStatus: (t: { bookingId: string; name: string | null; indexNumber: string | null }) => void;
}) {
  return (
    <div className="space-y-5">
      {missing.length > 0 && (
        <div data-testid="results-missing" className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          <p className="font-semibold">Missing scripts</p>
          <p className="mt-1">
            These {missing.length === 1 ? "candidate was" : "candidates were"} at the centre but {missing.length === 1 ? "has" : "have"} no script. Set{" "}
            {missing.length === 1 ? "their" : "each"} status before preparing the results.
          </p>
          <ul className="mt-2 space-y-1">
            {missing.map((m) => (
              <li key={m.bookingId} className="flex flex-wrap items-center gap-2">
                <span>{[m.name ?? "Unnamed", m.indexNumber].filter(Boolean).join(", ")}</span>
                <button type="button" disabled={busy} onClick={() => onSetStatus(m)} className={QUIET}>
                  Set status
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}

      {rows.length === 0 ? (
        <p className="text-sm text-slate-700">There are no candidates to show yet. Prepare the results to list them.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="py-2 pr-4 font-medium">Name</th>
                <th className="py-2 pr-4 font-medium">Index number</th>
                <th className="py-2 pr-4 font-medium">Mode</th>
                <th className="py-2 pr-4 font-medium">Status</th>
                <th className="py-2 pr-4 text-right font-medium">Total</th>
                <th className="py-2 pr-4 text-right font-medium">Percentage</th>
                <th className="py-2 pr-4 font-medium">Grade</th>
                <th className="py-2 pr-4 font-medium">Rank</th>
                <th className="py-2 font-medium">
                  <span className="sr-only">Actions</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.bookingId} className="border-b border-slate-100 align-top last:border-0">
                  <td className="py-2.5 pr-4 font-medium text-slate-900">{r.name ?? "Unnamed"}</td>
                  <td className="py-2.5 pr-4">{r.indexNumber ?? "—"}</td>
                  <td className="py-2.5 pr-4">{SITTING_LABEL[r.sitting]}</td>
                  <td className="py-2.5 pr-4">
                    <Badge tone={TONE[r.status]}>{STATUS_LABEL[r.status]}</Badge>
                    {r.remarked && <span className="ml-1 text-xs text-slate-500">Re-marked</span>}
                    {r.statusSet && r.statusReason && <p className="mt-1 max-w-xs text-xs text-slate-500">{r.statusReason}</p>}
                  </td>
                  <td className="py-2.5 pr-4 text-right tabular-nums">{show(r.total)}</td>
                  <td className="py-2.5 pr-4 text-right tabular-nums">{show(r.percentage, "%")}</td>
                  <td className="py-2.5 pr-4">{r.grade ?? "—"}</td>
                  <td className="py-2.5 pr-4 tabular-nums">
                    {r.rank === null ? "—" : r.rankCohort === null ? ordinal(r.rank) : `${ordinal(r.rank)} of ${r.rankCohort}`}
                  </td>
                  <td className="py-2.5 text-right">
                    <button type="button" disabled={busy} onClick={() => onSetStatus(r)} className={QUIET}>
                      Set status
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {more && (
        <p data-testid="results-more" role="status" className="text-sm text-amber-900">
          There are more than 2,000 candidates. The first 2,000, by index number, are shown. Download the CSV to see every one.
        </p>
      )}
    </div>
  );
}
