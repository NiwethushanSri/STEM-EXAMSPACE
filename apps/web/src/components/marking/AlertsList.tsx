"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { Badge } from "@/components/AppShell";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import { noteAlert, releaseAlert, releaseAllAlerts, type MarkingActionResult } from "@/app/marking/actions";
import { alertKindText, releaseBlockedText, ukDayTime, type AlertKind, type AlertRow } from "@/lib/marking-lists";

const QUIET = "min-h-11 rounded border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";

const KIND_LABEL: Record<AlertKind, string> = {
  picture_changed: "Picture changed",
  picture_missing: "Picture missing",
  name_visible: "Name visible",
  pages_set_aside: "Page set aside",
  pages_changed: "Pages changed",
};

type Step =
  | { kind: "release"; alert: AlertRow }
  | { kind: "note"; alert: AlertRow }
  | { kind: "release_all"; examId: string; examTitle: string };

/** The open marking alerts, by exam, for the lead marker of their subjects or an admin: "Release" for a changed
 * picture (or one plain sentence saying why it waits), "Noted" for changed or set-aside pages, and "Release all" for an
 * exam. Each asks for a reason. The script number and index number only; no candidate name. `scriptLinks` links each
 * script to its admin page. */
export function AlertsList({ alerts, scriptLinks = false }: { alerts: AlertRow[]; scriptLinks?: boolean }) {
  const router = useRouter();
  const [step, setStep] = useState<Step | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);

  const exams: { examId: string; examTitle: string; alerts: AlertRow[] }[] = [];
  for (const a of alerts) {
    const group = exams.find((e) => e.examId === a.examId);
    if (group) group.alerts.push(a);
    else exams.push({ examId: a.examId, examTitle: a.examTitle, alerts: [a] });
  }

  const open = (s: Step) => {
    setError(null);
    setStep(s);
  };
  const run = async (action: () => Promise<MarkingActionResult>) => {
    setBusy(true);
    const r = await action();
    setBusy(false);
    if (!r.ok) return setError(r.message);
    setStep(null);
    setDone(r.message);
    router.refresh();
  };
  const cancel = () => setStep(null);

  return (
    <div className="space-y-5">
      <div aria-live="polite">{done && <p className="text-sm text-green-800">{done}</p>}</div>
      {alerts.length === 0 && <p className="text-sm text-slate-600">Nothing needs your attention.</p>}
      {exams.map((e) => (
        <section key={e.examId} aria-label={`Alerts for ${e.examTitle}`} className="space-y-2">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h3 className="text-sm font-semibold text-slate-900">
              {e.examTitle} <span className="font-normal text-slate-600">· {e.alerts.length} open</span>
            </h3>
            {e.alerts.some((a) => a.canRelease) && (
              <button type="button" className={QUIET} onClick={() => open({ kind: "release_all", examId: e.examId, examTitle: e.examTitle })}>
                Release all
              </button>
            )}
          </div>
          <ul className="divide-y divide-slate-100 rounded border border-slate-200">
            {e.alerts.map((a) => (
              <li key={a.id} data-testid="marking-alert" className="flex flex-wrap items-start justify-between gap-3 px-3 py-3 text-sm">
                <div className="space-y-1">
                  <p>
                    <Badge tone="amber">{KIND_LABEL[a.kind]}</Badge>
                    <span className="ml-2 font-medium text-slate-900">Script {a.scriptNumber}</span>
                    {a.indexNumber && <span className="ml-2 text-slate-700">Index {a.indexNumber}</span>}
                    {a.pageN !== null && <span className="ml-2 text-slate-600">Page {a.pageN}</span>}
                  </p>
                  <p className="text-slate-700">{alertKindText(a.kind)}</p>
                  {a.kind === "picture_changed" && !a.canRelease && <p className="text-slate-700">{releaseBlockedText(a.releaseBlocked)}</p>}
                  {a.createdAt && <p className="text-xs text-slate-500">Raised {ukDayTime(a.createdAt)}</p>}
                </div>
                <div className="flex flex-wrap gap-2">
                  {scriptLinks && (
                    <Link href={`/admin/scripts/${a.scriptId}`} className={`${QUIET} inline-flex items-center`}>
                      Open the script
                    </Link>
                  )}
                  {a.canRelease && (
                    <button type="button" className={QUIET} onClick={() => open({ kind: "release", alert: a })} aria-label={`Release script ${a.scriptNumber}`}>
                      Release
                    </button>
                  )}
                  {(a.kind === "pages_set_aside" || a.kind === "pages_changed") && (
                    <button type="button" className={QUIET} onClick={() => open({ kind: "note", alert: a })} aria-label={`Noted, script ${a.scriptNumber}`}>
                      Noted
                    </button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        </section>
      ))}

      {step?.kind === "release" && (
        <ReasonDialog title={`Release script ${step.alert.scriptNumber}`} confirmLabel="Release" busy={busy} error={error} onCancel={cancel} onConfirm={(r) => run(() => releaseAlert(step.alert.id, r))}>
          <p className="text-sm text-slate-700">Its markers carry on marking it. A Next script hold starts again for two hours.</p>
        </ReasonDialog>
      )}
      {step?.kind === "note" && (
        <ReasonDialog title={`Noted: script ${step.alert.scriptNumber}`} confirmLabel="Noted" busy={busy} error={error} onCancel={cancel} onConfirm={(r) => run(() => noteAlert(step.alert.id, r))}>
          <p className="text-sm text-slate-700">The alert closes. Nothing else changes.</p>
        </ReasonDialog>
      )}
      {step?.kind === "release_all" && (
        <ReasonDialog title={`Release all for ${step.examTitle}`} confirmLabel="Release all" busy={busy} error={error} onCancel={cancel} onConfirm={(r) => run(() => releaseAllAlerts(step.examId, r))}>
          <p className="text-sm text-slate-700">Every changed picture of this exam that can be released now is released. The others stay open.</p>
        </ReasonDialog>
      )}
    </div>
  );
}
