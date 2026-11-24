"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { clearMarker, pauseMarker, sampleMarker, type ReviewActionResult } from "@/app/marking/review/actions";
import { Badge } from "@/components/AppShell";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import { totalText } from "@/lib/marking-feedback";
import { clearanceText, type ExamMarker } from "@/lib/marking-review";

const QUIET = "min-h-11 rounded border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";
const SAMPLE = 5;

type Step = { kind: "clear" | "pause"; marker: ExamMarker };

/** The exam's markers (the lead first): each one's clearance ("Cleared", or "Practice: 2 of 3 done" with each practice
 * total beside the lead marker's), misses in a row, and "Clear for live marking", "Pause" (each with a reason) and
 * "Review 5 of their scripts" (the routine sample). The lead is never offered these for themselves (`selfId`): the
 * database refuses them. Markers' names are shown; no candidate's. */
export function ExamMarkers({ examId, markers, selfId }: { examId: string; markers: ExamMarker[]; selfId: string }) {
  const router = useRouter();
  const [step, setStep] = useState<Step | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<{ ok: boolean; text: string } | null>(null);
  const [pending, start] = useTransition();

  const finish = (r: ReviewActionResult, said: string) => {
    if (!r.ok && step) return setError(r.message);
    setStep(null);
    setDone({ ok: r.ok, text: r.ok ? (r.message ?? said) : r.message });
    router.refresh();
  };
  const sample = (m: ExamMarker) =>
    start(async () => {
      setDone(null);
      finish(await sampleMarker(examId, m.markerId, SAMPLE), "Added to your sample.");
    });

  if (markers.length === 0) return <p className="text-sm text-slate-600">No marker is approved for this subject.</p>;
  return (
    <div className="space-y-4">
      <div aria-live="polite">{done && <p className={`text-sm ${done.ok ? "text-green-800" : "text-red-700"}`}>{done.text}</p>}</div>
      <ul className="divide-y divide-slate-100">
        {markers.map((m) => {
          const self = m.markerId === selfId;
          return (
            <li key={m.markerId} data-testid="exam-marker" className="space-y-2 py-4 text-sm">
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-medium text-slate-900">{m.name}</span>
                {m.lead && <Badge tone="blue">Lead marker</Badge>}
                {m.paused && <Badge tone="amber">Paused</Badge>}
                <span className={m.cleared ? "text-green-800" : "text-slate-700"}>{clearanceText(m)}</span>
              </div>
              {m.practice.length > 0 && (
                <ul className="space-y-1 text-slate-700">
                  {m.practice.map((p) => (
                    <li key={p.standardId} className="flex flex-wrap items-center gap-2">
                      <span>
                        Practice script {p.scriptNumber}: {totalText(p.total, p.maxTotal)} (lead marker: {totalText(p.leadTotal, p.maxTotal)})
                      </span>
                      {!p.within && <Badge tone="amber">Different</Badge>}
                    </li>
                  ))}
                </ul>
              )}
              <p className="text-slate-700">Misses in a row: {m.misses}</p>
              {!self && (
                <div className="flex flex-wrap gap-2">
                  {(!m.cleared || m.paused) && (
                    <button type="button" className={QUIET} disabled={pending} onClick={() => setStep({ kind: "clear", marker: m })}>
                      Clear for live marking
                    </button>
                  )}
                  {!m.paused && (
                    <button type="button" className={QUIET} disabled={pending} onClick={() => setStep({ kind: "pause", marker: m })}>
                      Pause
                    </button>
                  )}
                  <button type="button" className={QUIET} disabled={pending} onClick={() => sample(m)}>
                    Review {SAMPLE} of their scripts
                  </button>
                </div>
              )}
            </li>
          );
        })}
      </ul>
      {step && (
        <ReasonDialog
          title={step.kind === "clear" ? `Clear ${step.marker.name} for live marking` : `Pause ${step.marker.name}`}
          confirmLabel={step.kind === "clear" ? "Clear for live marking" : "Pause"}
          tone={step.kind === "pause" ? "danger" : "primary"}
          busy={pending}
          error={error}
          onCancel={() => {
            setStep(null);
            setError(null);
          }}
          onConfirm={(reason) =>
            start(async () => {
              setError(null);
              const r = step.kind === "clear" ? await clearMarker(examId, step.marker.markerId, reason) : await pauseMarker(examId, step.marker.markerId, reason);
              finish(r, step.kind === "clear" ? "Cleared for live marking." : "Paused.");
            })
          }
        >
          <p className="text-sm text-slate-700">
            {step.kind === "clear"
              ? "They can then mark live scripts. A pause ends, and their misses start again from none."
              : "Next script gives them nothing on this exam. The scripts they submitted come to you to accept or send back."}
          </p>
        </ReasonDialog>
      )}
    </div>
  );
}
