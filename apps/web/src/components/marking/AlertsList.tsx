"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useEffectEvent, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { alertMessageFor } from "@stem/shared";
import { Badge } from "@/components/AppShell";
import { PagesViewer } from "@/components/marking/PagesViewer";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import { noteAlert, releaseAlert, releaseAllAlerts, type MarkingActionResult } from "@/app/marking/actions";
import {
  alertKindText,
  alertPagesViewable,
  firstShownText,
  parseAlertPages,
  releaseBlockedText,
  ukDayTime,
  type AlertKind,
  type AlertPages,
  type AlertRow,
} from "@/lib/marking-lists";
import { createClient } from "@/lib/supabase/client";

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
  | { kind: "release_all"; examId: string; examTitle: string }
  | { kind: "pages"; alert: AlertRow; pages: AlertPages };

/** The open marking alerts, by exam, for the lead marker of their subjects or an admin: "Release" for a changed
 * picture (or one plain sentence saying why it waits), "View pages" beside it to look at the script's pages first (the
 * changed one marked), "Noted" for changed or set-aside pages, and "Release all" for an exam. Each change asks for a
 * reason. A lead with a declared conflict for the candidate sees neither Release nor the pages. The script number and
 * index number only; no candidate name. `scriptLinks` links each script to its admin page. `more`: the list was cut
 * short (marking_alerts_list sends at most 500), and says so. */
export function AlertsList({ alerts, scriptLinks = false, more = false }: { alerts: AlertRow[]; scriptLinks?: boolean; more?: boolean }) {
  const router = useRouter();
  const [step, setStep] = useState<Step | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  /** The alert whose pages are being asked for, and why the last ask failed (by alert). */
  const [opening, setOpening] = useState<string | null>(null);
  const [pagesError, setPagesError] = useState<{ id: string; message: string } | null>(null);

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
  /** "View pages": the script's pages (marking_alert_pages, which checks the lead again), then the viewer. */
  const viewPages = async (a: AlertRow) => {
    setOpening(a.id);
    setPagesError(null);
    const { data, error: e } = await createClient()
      .rpc("marking_alert_pages", { p_alert: a.id })
      .then((r) => r, () => ({ data: null, error: true }));
    setOpening(null);
    const r = e ? ({ ok: false, code: "internal" } as const) : parseAlertPages(data);
    if (!r.ok) return setPagesError({ id: a.id, message: alertMessageFor(r.code) });
    open({ kind: "pages", alert: a, pages: r });
  };

  return (
    <div className="space-y-5">
      <div aria-live="polite">{done && <p className="text-sm text-green-800">{done}</p>}</div>
      {alerts.length === 0 && <p className="text-sm text-slate-600">Nothing needs your attention.</p>}
      {more && <p className="text-sm text-slate-600">{firstShownText(alerts.length)}</p>}
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
                  {pagesError?.id === a.id && (
                    <p role="alert" className="text-red-700">
                      {pagesError.message}
                    </p>
                  )}
                </div>
                <div className="flex flex-wrap gap-2">
                  {scriptLinks && (
                    <Link href={`/admin/scripts/${a.scriptId}`} className={`${QUIET} inline-flex items-center`}>
                      Open the script
                    </Link>
                  )}
                  {alertPagesViewable(a) && (
                    <button
                      type="button"
                      className={QUIET}
                      disabled={opening === a.id}
                      onClick={() => void viewPages(a)}
                      aria-label={`View pages of script ${a.scriptNumber}`}
                    >
                      {opening === a.id ? "Opening…" : "View pages"}
                    </button>
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
      {step?.kind === "pages" && (
        <ViewerDialog title={`Pages of script ${step.alert.scriptNumber}`} onClose={cancel}>
          <p className="text-sm text-slate-700">
            {step.pages.indexNumber ? `Index ${step.pages.indexNumber}. ` : ""}The changed page is marked. Look at it before you release the script.
          </p>
          <PagesViewer
            unitId={step.pages.unitId}
            pages={step.pages.pages.map((p) => ({ n: p.n, page_id: p.pageId, has_picture: p.hasPicture }))}
            highlight={step.pages.pages.find((p) => p.changed)?.pageId}
          />
        </ViewerDialog>
      )}
      {step?.kind === "release_all" && (
        <ReasonDialog title={`Release all for ${step.examTitle}`} confirmLabel="Release all" busy={busy} error={error} onCancel={cancel} onConfirm={(r) => run(() => releaseAllAlerts(step.examId, r))}>
          <p className="text-sm text-slate-700">Every changed picture of this exam that can be released now is released. The others stay open.</p>
        </ReasonDialog>
      )}
    </div>
  );
}

/** What Tab may move to inside a box. */
const FOCUSABLE = 'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/** A wide modal box for the page viewer: Escape, the backdrop and Close close it; focus starts on Close, Tab and
 * Shift+Tab stay inside it while it is open, and focus goes back to what opened it. */
function ViewerDialog({ title, children, onClose }: { title: string; children: ReactNode; onClose: () => void }) {
  const close = useRef<HTMLButtonElement>(null);
  const panel = useRef<HTMLDivElement>(null);
  const onEscape = useEffectEvent(onClose);
  useLayoutEffect(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    return () => {
      queueMicrotask(() => {
        if (opener?.isConnected) opener.focus();
      });
    };
  }, []);
  useEffect(() => {
    close.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") return onEscape();
      if (e.key !== "Tab" || !panel.current) return;
      const items = [...panel.current.querySelectorAll<HTMLElement>(FOCUSABLE)];
      if (items.length === 0) return;
      const first = items[0];
      const last = items[items.length - 1];
      const at = document.activeElement;
      const inside = at instanceof Node && panel.current.contains(at);
      if (e.shiftKey && (at === first || !inside)) {
        e.preventDefault();
        last.focus();
      } else if (!e.shiftKey && (at === last || !inside)) {
        e.preventDefault();
        first.focus();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4" onClick={onClose}>
      <div
        ref={panel}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        className="max-h-full w-full max-w-3xl space-y-3 overflow-y-auto rounded-lg bg-white p-4 shadow-xl sm:p-6"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between gap-3">
          <h2 className="text-base font-semibold text-slate-900">{title}</h2>
          <button ref={close} type="button" className={QUIET} onClick={onClose}>
            Close
          </button>
        </div>
        {children}
      </div>
    </div>
  );
}
