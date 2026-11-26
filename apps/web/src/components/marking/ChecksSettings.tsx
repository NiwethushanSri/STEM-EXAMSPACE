"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import { saveChecksAction, type MarkingActionResult } from "@/app/admin/exams/[id]/actions";
import { checksNeedReason, checksOffLine, checksProblem, checksTurnOff, type CheckSettings, type ChecksView } from "@/lib/exam-marking";

const GENERIC = "Something went wrong. Please try again.";
const NUMBER = "w-16 rounded border border-slate-300 px-2 py-1 text-sm disabled:bg-slate-50 disabled:text-slate-500";

type Switch = "doubleMarking" | "seeds" | "practice";

/** The checks on an exam's marking: double marking, seeded scripts and practice, each on unless turned off with a
 * reason while the subject has one approved marker. The database re-checks every rule (marking_checks_set). */
export function ChecksSettings({ examId, checks }: { examId: string; checks: ChecksView | null }) {
  if (!checks) {
    return (
      <p role="alert" className="mt-2 text-sm text-red-700">
        The checks could not be loaded. Refresh the page.
      </p>
    );
  }
  return <Checks examId={examId} saved={checks} />;
}

function Checks({ examId, saved }: { examId: string; saved: ChecksView }) {
  const router = useRouter();
  const [on, setOn] = useState<Record<Switch, boolean>>({ doubleMarking: saved.doubleMarking, seeds: saved.seeds, practice: saved.practice });
  const [sample, setSample] = useState(String(saved.samplePercent));
  const [tolerance, setTolerance] = useState(String(saved.tolerancePercent));
  const [seedEvery, setSeedEvery] = useState(String(saved.seedEvery));
  const [busy, setBusy] = useState(false);
  const [asking, setAsking] = useState<CheckSettings | null>(null);
  const [dialogError, setDialogError] = useState<string | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const next = (): CheckSettings => ({
    ...on,
    samplePercent: Number(sample),
    tolerancePercent: Number(tolerance),
    seedEvery: Number(seedEvery),
  });

  async function save(settings: CheckSettings, reason?: string) {
    setBusy(true);
    const res = await saveChecksAction(examId, settings, reason).catch((): MarkingActionResult => ({ ok: false, message: GENERIC }));
    setBusy(false);
    if (res.ok) {
      setAsking(null);
      setNotice(res.message);
      router.refresh();
    } else if (reason !== undefined) {
      setDialogError(res.message);
    } else if (res.reasonRequired) {
      ask(settings);
    } else {
      setFormError(res.message);
    }
  }

  function ask(settings: CheckSettings) {
    setDialogError(null);
    setAsking(settings);
  }

  function onSave(e: React.FormEvent) {
    e.preventDefault();
    setFormError(null);
    setNotice(null);
    const settings = next();
    const problem = checksProblem(settings);
    if (problem) return setFormError(problem);
    // Turning a check off, or any change once marking has opened, needs a reason: ask for it first.
    if (checksNeedReason(saved, settings)) return ask(settings);
    void save(settings);
  }

  /** A check that is on cannot be turned off unless the subject has at most one approved marker. */
  const locked = (key: Switch) => busy || (saved[key] && !saved.canSwitchOff);
  const toggle = (key: Switch) => (
    <input type="checkbox" checked={on[key]} disabled={locked(key)} onChange={(e) => setOn({ ...on, [key]: e.target.checked })} />
  );

  return (
    <div className="mt-6 border-t border-slate-100 pt-4">
      <h3 className="text-sm font-semibold text-slate-800">Checks on the marking</h3>
      {notice && (
        <div role="status" className="mt-2 rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">
          {notice}
        </div>
      )}
      {saved.off && (
        <p data-testid="checks-off" className="mt-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          {checksOffLine(saved.off)}
        </p>
      )}
      {saved.canSwitchOff && (
        <p className="mt-2 text-sm text-slate-700">
          {saved.markersApproved === 0 ? "This subject has no approved marker yet." : "This subject has one approved marker."} You can turn these
          checks off with a reason. The reason is shown when the marking is approved.
        </p>
      )}

      <form onSubmit={onSave} aria-label="Checks on the marking" className="mt-3 space-y-3 text-sm text-slate-700">
        <div>
          <label className="flex items-center gap-2 font-medium text-slate-800">
            {toggle("doubleMarking")}
            Double marking
          </label>
          <div className="ml-6 mt-1 space-y-1">
            <label className="block">
              Second-mark{" "}
              <input type="number" min={1} max={100} step={1} value={sample} disabled={busy || !on.doubleMarking} onChange={(e) => setSample(e.target.value)} className={NUMBER} />
              % of scripts
            </label>
            <label className="block">
              Send to the lead marker when marks differ by more than{" "}
              <input type="number" min={1} max={50} step={1} value={tolerance} disabled={busy || !on.doubleMarking} onChange={(e) => setTolerance(e.target.value)} className={NUMBER} />
              % of the maximum
            </label>
          </div>
        </div>
        <div>
          <label className="flex items-center gap-2 font-medium text-slate-800">
            {toggle("seeds")}
            Seeded scripts
          </label>
          <label className="ml-6 mt-1 block">
            About one in every{" "}
            <input type="number" min={3} max={50} step={1} value={seedEvery} disabled={busy || !on.seeds} onChange={(e) => setSeedEvery(e.target.value)} className={NUMBER} />
            {" "}scripts
          </label>
        </div>
        <label className="flex items-center gap-2 font-medium text-slate-800">
          {toggle("practice")}
          Practice before live marking
        </label>
        {!saved.canSwitchOff && (saved.doubleMarking || saved.seeds || saved.practice) && (
          <p className="text-xs text-slate-500">These checks can only be turned off when the subject has one approved marker.</p>
        )}
        {saved.opened && <p className="text-xs text-slate-500">Marking has opened, so a change needs a reason.</p>}
        {formError && (
          <p role="alert" className="text-sm text-red-700">
            {formError}
          </p>
        )}
        <button type="submit" disabled={busy} className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60">
          Save checks
        </button>
      </form>

      {asking && (
        <ReasonDialog
          title={checksTurnOff(saved, asking) ? "Turn checks off?" : "Change the checks?"}
          confirmLabel="Save checks"
          busy={busy}
          error={dialogError}
          onConfirm={(reason) => save(asking, reason)}
          onCancel={() => setAsking(null)}
        >
          <p className="text-sm text-slate-700">
            {checksTurnOff(saved, asking)
              ? "The reason is kept with your name and shown when the marking is approved."
              : "Marking has opened, so the change is recorded with your reason."}
          </p>
        </ReasonDialog>
      )}
    </div>
  );
}
