"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import { setRates, type PayActionResult } from "@/app/admin/marking/payments/actions";
import { RATE_PROBLEM, readRates, type RatesView } from "@/lib/marker-pay";
import { penceToInput } from "@/lib/money";

const GENERIC = "Something went wrong. Please try again.";
const BOX = "w-28 rounded border border-slate-300 px-2 py-1 text-sm disabled:bg-slate-50 disabled:text-slate-500";

/** 3B Task 12: what markers are paid for this exam's marking, per script, or per question group for an exam marked by
 * question. Once some of its marking is in a fixed statement a change needs a reason, and fixed statements keep their
 * pay. The database checks every rule again (marker_rates_set). */
export function PayRates({ examId, rates }: { examId: string; rates: RatesView | null }) {
  return (
    <div className="mt-6 border-t border-slate-100 pt-4">
      <h3 className="text-sm font-semibold text-slate-800">Marker pay</h3>
      {rates ? (
        <Rates key={`${rates.mode}:${rates.rates.map((r) => r.groupId).join()}`} examId={examId} saved={rates} />
      ) : (
        <p role="alert" className="mt-2 text-sm text-red-700">
          The pay rates could not be loaded. Refresh the page.
        </p>
      )}
    </div>
  );
}

function Rates({ examId, saved }: { examId: string; saved: RatesView }) {
  const router = useRouter();
  const [texts, setTexts] = useState(saved.rates.map((r) => (r.pence === null ? "" : penceToInput(r.pence))));
  const [busy, setBusy] = useState(false);
  const [asking, setAsking] = useState<number[] | null>(null);
  const [dialogError, setDialogError] = useState<string | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const fixed = saved.fixedPieces > 0;
  const unset = saved.rates.some((r) => r.pence === null);

  async function save(pence: number[], reason?: string) {
    setBusy(true);
    const list = saved.rates.map((r, i) => ({ groupId: r.groupId, pence: pence[i] }));
    const res = await setRates(examId, list, reason).catch((): PayActionResult => ({ ok: false, message: GENERIC }));
    setBusy(false);
    if (res.ok) {
      setAsking(null);
      setNotice(res.message);
      router.refresh();
    } else if (reason !== undefined) {
      setDialogError(res.message);
    } else if (res.reasonRequired) {
      ask(pence);
    } else {
      setFormError(res.message);
    }
  }

  function ask(pence: number[]) {
    setDialogError(null);
    setAsking(pence);
  }

  function onSave(e: React.FormEvent) {
    e.preventDefault();
    setFormError(null);
    setNotice(null);
    const pence = readRates(texts);
    if (!pence) return setFormError(RATE_PROBLEM);
    if (pence.every((p, i) => p === saved.rates[i].pence)) return setNotice("The pay rates are unchanged.");
    // Some of this exam's marking is in a fixed statement: a change needs a reason, so ask for it first.
    if (fixed) return ask(pence);
    void save(pence);
  }

  if (saved.rates.length === 0) {
    return <p className="mt-2 text-sm text-slate-700">There are no question groups yet. Add them under Questions and mark scheme.</p>;
  }

  return (
    <>
      {notice && (
        <div role="status" className="mt-2 rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">
          {notice}
        </div>
      )}
      <form onSubmit={onSave} aria-label="Marker pay" className="mt-3 space-y-3 text-sm text-slate-700">
        {saved.mode === "whole" ? (
          <RateBox label="Pay per script" value={texts[0]} busy={busy} onChange={(v) => setTexts([v])} />
        ) : (
          <fieldset className="space-y-2">
            <legend className="font-medium text-slate-800">Pay per question group</legend>
            {saved.rates.map((r, i) => (
              <RateBox
                key={r.groupId ?? i}
                label={r.label ?? "Question group"}
                value={texts[i]}
                busy={busy}
                onChange={(v) => setTexts(texts.map((t, j) => (j === i ? v : t)))}
              />
            ))}
          </fieldset>
        )}
        {unset && <p className="text-xs text-slate-500">No rate is set yet. Statements with this exam&apos;s marking cannot be fixed until every rate is set.</p>}
        <p className="text-xs text-slate-500">
          In pounds, from £0 to £1,000. First marking, second marking and re-marking are paid at the same rate. Practice and seeded scripts are
          not paid.
        </p>
        {fixed && (
          <p className="text-xs text-slate-500">
            Some of this exam&apos;s marking is in a fixed statement, so a change needs a reason. Fixed statements keep the rate they were fixed
            at.
          </p>
        )}
        {formError && (
          <p role="alert" className="text-sm text-red-700">
            {formError}
          </p>
        )}
        <button type="submit" disabled={busy} className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60">
          Save pay rates
        </button>
      </form>

      {asking && (
        <ReasonDialog
          title="Change the pay rates?"
          confirmLabel="Save pay rates"
          busy={busy}
          error={dialogError}
          onConfirm={(reason) => save(asking, reason)}
          onCancel={() => setAsking(null)}
        >
          <p className="text-sm text-slate-700">
            The new rates reach only marking that is not in a fixed statement yet. The change is recorded with your reason.
          </p>
        </ReasonDialog>
      )}
    </>
  );
}

function RateBox({ label, value, busy, onChange }: { label: string; value: string; busy: boolean; onChange: (v: string) => void }) {
  return (
    <label className="flex flex-wrap items-center gap-2">
      <span className="min-w-32 font-medium text-slate-800">{label}</span>
      <span aria-hidden="true">£</span>
      <input type="text" inputMode="decimal" autoComplete="off" value={value} disabled={busy} onChange={(e) => onChange(e.target.value)} className={BOX} />
    </label>
  );
}
