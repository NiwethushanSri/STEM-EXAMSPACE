"use client";

import { useState } from "react";
import { Card } from "@/components/AppShell";
import { previewBoundaries, saveBoundaries, type PreviewResult, type ResultsActionResult } from "@/app/admin/results/[examId]/actions";
import { MAX_GRADES, type Boundary, type BoundaryInput } from "@/lib/results-admin";

const GENERIC = "Something went wrong. Please try again.";
const FIELD = "rounded border border-slate-300 px-3 py-2 text-sm";
const PRIMARY = "rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50";
const QUIET = "rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";

const fromBoundaries = (b: Boundary[]): BoundaryInput[] => b.map((x) => ({ grade: x.grade, mark: String(x.minMark) }));

/** The grade boundaries: one line per grade, top grade first, with its lowest mark. "Preview" counts the candidates in
 * each grade without saving; "Save boundaries" saves them (an empty list clears them) with an optional reason. Locked
 * once results are scheduled or published. The editor is keyed by the saved boundaries, so it starts again from them
 * after a save. */
export function BoundariesEditor({
  examId,
  boundaries,
  maxTotal,
  locked,
  prepared,
  onDone,
}: {
  examId: string;
  boundaries: Boundary[];
  maxTotal: number | null;
  locked: boolean;
  prepared: boolean;
  /** Called with each action's answer so the page can show it and read the results again. */
  onDone: (res: ResultsActionResult) => void;
}) {
  const [rows, setRows] = useState<BoundaryInput[]>(() => fromBoundaries(boundaries));
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [preview, setPreview] = useState<Extract<PreviewResult, { ok: true }> | null>(null);
  const [error, setError] = useState<string | null>(null);

  function edit(i: number, patch: Partial<BoundaryInput>) {
    setRows((rs) => rs.map((r, j) => (j === i ? { ...r, ...patch } : r)));
    setPreview(null);
  }

  async function doPreview() {
    setBusy(true);
    setError(null);
    const res = await previewBoundaries(examId, rows, maxTotal).catch((): PreviewResult => ({ ok: false, message: GENERIC }));
    setBusy(false);
    if (res.ok) setPreview(res);
    else {
      setPreview(null);
      setError(res.message);
    }
  }

  async function doSave() {
    setBusy(true);
    setError(null);
    const res = await saveBoundaries(examId, rows, maxTotal, reason).catch((): ResultsActionResult => ({ ok: false, message: GENERIC }));
    setBusy(false);
    if (res.ok) {
      setReason("");
      setPreview(null);
    } else setError(res.message);
    onDone(res);
  }

  return (
    <Card title="Grade boundaries">
      {locked ? (
        <p className="mb-3 text-sm text-slate-600">The boundaries are locked while the results are scheduled or published. Withdraw or cancel first to change them.</p>
      ) : (
        <p className="mb-3 text-sm text-slate-600">
          List the grades from the top down. Each grade starts at its lowest mark{maxTotal !== null ? `, out of ${maxTotal}` : ""}. Anyone below the last grade gets U.
        </p>
      )}
      {!prepared && !locked && <p className="mb-3 text-sm text-slate-600">Prepare the results first to see how many candidates each grade gives.</p>}

      {rows.length === 0 ? (
        <p className="text-sm text-slate-700">No grades are set.</p>
      ) : (
        <ul className="space-y-2" data-testid="boundary-rows">
          {rows.map((r, i) => (
            <li key={i} className="flex flex-wrap items-end gap-3">
              <label className="flex flex-col gap-1 text-sm">
                <span className="text-xs text-slate-500">Grade {i + 1}</span>
                <input
                  value={r.grade}
                  disabled={locked || busy}
                  maxLength={10}
                  onChange={(e) => edit(i, { grade: e.target.value })}
                  aria-label={`Grade ${i + 1} label`}
                  className={`${FIELD} w-24`}
                />
              </label>
              <label className="flex flex-col gap-1 text-sm">
                <span className="text-xs text-slate-500">Lowest mark</span>
                <input
                  value={r.mark}
                  inputMode="decimal"
                  disabled={locked || busy}
                  onChange={(e) => edit(i, { mark: e.target.value })}
                  aria-label={`Grade ${i + 1} lowest mark`}
                  className={`${FIELD} w-28`}
                />
              </label>
              {!locked && (
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => {
                    setRows((rs) => rs.filter((_, j) => j !== i));
                    setPreview(null);
                  }}
                  className={QUIET}
                >
                  Remove
                </button>
              )}
            </li>
          ))}
        </ul>
      )}

      {!locked && (
        <div className="mt-3 space-y-3">
          <button
            type="button"
            disabled={busy || rows.length >= MAX_GRADES}
            onClick={() => {
              setRows((rs) => [...rs, { grade: "", mark: "" }]);
              setPreview(null);
            }}
            className={QUIET}
          >
            Add a grade
          </button>

          <label className="block max-w-md text-sm">
            <span className="font-medium text-slate-700">Reason (optional)</span>
            <input value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} className={`${FIELD} mt-1 w-full`} />
            <span className="text-xs text-slate-500">3 to 300 characters, or leave it empty. It goes into the audit log.</span>
          </label>

          <div className="flex flex-wrap gap-2">
            <button type="button" disabled={busy || rows.length === 0} onClick={() => void doPreview()} className={QUIET}>
              Preview
            </button>
            <button type="button" disabled={busy} onClick={() => void doSave()} className={PRIMARY}>
              Save boundaries
            </button>
          </div>
        </div>
      )}

      <div aria-live="polite">
        {error && (
          <p role="alert" className="mt-3 text-sm text-red-700">
            {error}
          </p>
        )}
      </div>

      {preview && (
        <div data-testid="boundary-preview" className="mt-4">
          <p className="text-sm font-medium text-slate-900">Preview (not saved)</p>
          <div className="mt-1 overflow-x-auto">
            <table className="w-full max-w-md text-left text-sm">
              <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="py-2 pr-4 font-medium">Grade</th>
                  <th className="py-2 pr-4 text-right font-medium">All</th>
                  <th className="py-2 pr-4 text-right font-medium">Centre</th>
                  <th className="py-2 text-right font-medium">Home</th>
                </tr>
              </thead>
              <tbody>
                {preview.grades.map((g) => (
                  <tr key={g.grade} className="border-b border-slate-100">
                    <td className="py-2 pr-4">{g.grade}</td>
                    <td className="py-2 pr-4 text-right tabular-nums">{g.all}</td>
                    <td className="py-2 pr-4 text-right tabular-nums">{g.centre}</td>
                    <td className="py-2 text-right tabular-nums">{g.home}</td>
                  </tr>
                ))}
                <tr>
                  <td className="py-2 pr-4">U</td>
                  <td className="py-2 pr-4 text-right tabular-nums">{preview.below.all}</td>
                  <td className="py-2 pr-4 text-right tabular-nums">{preview.below.centre}</td>
                  <td className="py-2 text-right tabular-nums">{preview.below.home}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      )}
    </Card>
  );
}
