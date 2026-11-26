"use client";

import { useRouter } from "next/navigation";
import { useId, useState, useTransition } from "react";
import { retireStandard, setStandard, type ReviewActionResult } from "@/app/marking/review/actions";
import { Badge } from "@/components/AppShell";
import { ConfirmDialog } from "@/components/accounts/ConfirmDialog";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import { totalText } from "@/lib/marking-feedback";
import { firstShownText } from "@/lib/marking-lists";
import { noteProblem, type Standard, type StandardCandidate, type StandardUse } from "@/lib/marking-review";

const QUIET = "min-h-11 rounded border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";
const USE_TEXT: Record<StandardUse, string> = { practice: "Practice", seed: "Seeded script" };

type Step = { kind: "use"; use: StandardUse; piece: StandardCandidate } | { kind: "retire"; standard: Standard };

const where = (s: { scriptNumber: string; indexNumber: string | null; groupLabel: string | null }) =>
  [`Script ${s.scriptNumber}`, s.indexNumber ? `Index ${s.indexNumber}` : null, s.groupLabel].filter(Boolean).join(" · ");

/** The exam's practice and seeded scripts with their attempts, and "Stop using" (a reason); for the lead marker, also
 * the scripts they marked themselves, each with "Use for practice" and "Use as a seeded script" (an optional note to
 * the markers, "Why these marks"). `canAdd` is null for an admin, who cannot make one. No candidate name. */
export function Standards({ standards, canAdd, more }: { standards: Standard[]; canAdd: StandardCandidate[] | null; more: boolean }) {
  const router = useRouter();
  const [step, setStep] = useState<Step | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const finish = (r: ReviewActionResult, said: string) => {
    if (!r.ok) return setError(r.message);
    setStep(null);
    setError(null);
    setDone(r.message ?? said);
    router.refresh();
  };
  /** A new dialog starts with no old refusal shown (Ruling R18). */
  const open = (st: Step) => {
    setError(null);
    setDone(null);
    setStep(st);
  };
  const cancel = () => {
    setStep(null);
    setError(null);
  };

  return (
    <div className="space-y-6">
      <div aria-live="polite">{done && <p className="text-sm text-green-800">{done}</p>}</div>
      {canAdd && (
        <section aria-label="Scripts you marked" className="space-y-2">
          <h3 className="text-sm font-semibold text-slate-900">Scripts you marked</h3>
          {canAdd.length === 0 ? (
            <p className="text-sm text-slate-600">You have no submitted script to use yet. Mark a few, then choose them here.</p>
          ) : (
            <ul className="divide-y divide-slate-100">
              {canAdd.map((p) => (
                <li key={p.unitId} data-testid="standard-candidate" className="flex flex-wrap items-center justify-between gap-3 py-3 text-sm">
                  <span>
                    <span className="font-medium text-slate-900">{where(p)}</span>
                    <span className="ml-2 tabular-nums text-slate-700">Your total: {totalText(p.total, null)}</span>
                  </span>
                  <span className="flex flex-wrap gap-2">
                    <button type="button" className={QUIET} disabled={pending} onClick={() => open({ kind: "use", use: "practice", piece: p })}>
                      Use for practice
                    </button>
                    <button type="button" className={QUIET} disabled={pending} onClick={() => open({ kind: "use", use: "seed", piece: p })}>
                      Use as a seeded script
                    </button>
                  </span>
                </li>
              ))}
            </ul>
          )}
          {more && <p className="text-sm text-slate-600">{firstShownText(canAdd.length)}</p>}
        </section>
      )}

      <section aria-label="Practice and seeded scripts in use" className="space-y-2">
        <h3 className="text-sm font-semibold text-slate-900">Practice and seeded scripts</h3>
        {standards.length === 0 ? (
          <p className="text-sm text-slate-600">None yet.</p>
        ) : (
          <ul className="divide-y divide-slate-100">
            {standards.map((s) => (
              <li key={s.id} data-testid="standard" className="flex flex-wrap items-start justify-between gap-3 py-3 text-sm">
                <div className="space-y-1">
                  <p className="flex flex-wrap items-center gap-2">
                    <Badge tone={s.use === "practice" ? "blue" : "slate"}>{USE_TEXT[s.use]}</Badge>
                    <span className="font-medium text-slate-900">{where(s)}</span>
                    <span className="tabular-nums text-slate-700">{totalText(s.total, s.maxTotal)}</span>
                    {s.retired && <Badge tone="slate">No longer used</Badge>}
                  </p>
                  <p className="text-slate-700">
                    {s.attempts.done} {s.attempts.done === 1 ? "attempt" : "attempts"}, {s.attempts.outside} outside the tolerance
                  </p>
                  {s.note && <p className="whitespace-pre-wrap text-slate-600">Why these marks: {s.note}</p>}
                </div>
                {!s.retired && (
                  <button type="button" className={QUIET} disabled={pending} onClick={() => open({ kind: "retire", standard: s })}>
                    Stop using
                  </button>
                )}
              </li>
            ))}
          </ul>
        )}
      </section>

      {step?.kind === "use" && (
        <UseDialog
          use={step.use}
          piece={step.piece}
          busy={pending}
          error={error}
          onCancel={cancel}
          onConfirm={(note) =>
            start(async () => finish(await setStandard(step.piece.unitId, step.use, note || undefined), step.use === "practice" ? "Used for practice." : "Used as a seeded script."))
          }
        />
      )}
      {step?.kind === "retire" && (
        <ReasonDialog
          title={`Stop using script ${step.standard.scriptNumber}`}
          confirmLabel="Stop using"
          tone="danger"
          busy={pending}
          error={error}
          onCancel={cancel}
          onConfirm={(reason) => start(async () => finish(await retireStandard(step.standard.id, reason), "No longer used."))}
        >
          <p className="text-sm text-slate-700">Markers are given it no more. Attempts already submitted stand.</p>
        </ReasonDialog>
      )}
    </div>
  );
}

/** Use a script for practice or as a seeded script: an optional note to the markers, checked here (3 to 1,000
 * characters when given). */
function UseDialog({
  use,
  piece,
  busy,
  error,
  onConfirm,
  onCancel,
}: {
  use: StandardUse;
  piece: StandardCandidate;
  busy: boolean;
  error: string | null;
  onConfirm: (note: string) => void;
  onCancel: () => void;
}) {
  const id = useId();
  const [note, setNote] = useState("");
  const [problem, setProblem] = useState<string | null>(null);
  return (
    <ConfirmDialog
      title={use === "practice" ? `Use script ${piece.scriptNumber} for practice` : `Use script ${piece.scriptNumber} as a seeded script`}
      confirmLabel={use === "practice" ? "Use for practice" : "Use as a seeded script"}
      tone="primary"
      busy={busy}
      onCancel={() => {
        if (!busy) onCancel();
      }}
      onConfirm={() => {
        const p = noteProblem(note, false);
        setProblem(p);
        if (!p) onConfirm(note.trim());
      }}
    >
      <div className="space-y-3 text-sm">
        <p className="text-slate-700">
          {use === "practice"
            ? "Markers mark it before live marking and then see your marks."
            : "It is mixed into markers' scripts unannounced. A marker outside the tolerance is shown your marks."}{" "}
          Your marks are kept as they are now. It is never second-marked.
        </p>
        <label htmlFor={id} className="block font-medium text-slate-800">
          Why these marks (optional)
        </label>
        <textarea id={id} value={note} maxLength={1000} rows={3} onChange={(e) => setNote(e.target.value)} className="w-full rounded border border-slate-300 px-3 py-2" />
        <p className="text-xs text-slate-500">If you give one, 3 to 1,000 characters. Markers see it with your marks.</p>
        {(problem ?? error) && (
          <p role="alert" className="text-red-700">
            {problem ?? error}
          </p>
        )}
      </div>
    </ConfirmDialog>
  );
}
