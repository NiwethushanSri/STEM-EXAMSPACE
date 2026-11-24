"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Badge, Card } from "@/components/AppShell";
import { ConfirmDialog } from "@/components/accounts/ConfirmDialog";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import { ChecksSettings } from "@/components/marking/ChecksSettings";
import {
  closeMarkingAction,
  openMarkingAction,
  reopenMarkingAction,
  saveMarkingSettingsAction,
  type MarkingActionResult,
} from "@/app/admin/exams/[id]/actions";
import { markingChecks, type ChecksView, type MarkingGroup, type MarkingMode, type MarkingView } from "@/lib/exam-marking";
import { utcToLondonParts } from "@/lib/london-time";
import { formatLondon } from "@/lib/money";

const GENERIC = "Something went wrong. Please try again.";
const FIELD = "mt-1 rounded border border-slate-300 px-3 py-2 text-sm disabled:bg-slate-50 disabled:text-slate-500";

type Dialog = "open" | "close" | "reopen" | "deadline";

/** How the exam is marked, its marking deadline, the checks on the marking, what opening waits for, and Open, Close
 * and Reopen. 3B Task 10: once marking has opened, a link to the exam's approval page ("Approve marking", or
 * "Approved"); an approved exam says so and offers no Reopen until an admin withdraws the approval. */
export function ExamMarkingPanel({
  examId,
  view,
  checks,
  groups,
  finishesAt,
  homeUntil,
}: {
  examId: string;
  view: MarkingView | null;
  /** Null when the checks could not be loaded. */
  checks: ChecksView | null;
  groups: MarkingGroup[];
  /** When the exam finishes: the deadline must be after it. */
  finishesAt: string;
  /** When home scripts may be handed out (the finish + 24 hours). */
  homeUntil: string;
}) {
  if (!view) {
    return (
      <Card title="Marking">
        <p role="alert" className="text-sm text-red-700">
          The marking settings could not be loaded. Refresh the page.
        </p>
      </Card>
    );
  }
  return <Panel examId={examId} view={view} checks={checks} groups={groups} finishesAt={finishesAt} homeUntil={homeUntil} />;
}

function Panel({
  examId,
  view,
  checks,
  groups,
  finishesAt,
  homeUntil,
}: {
  examId: string;
  view: MarkingView;
  checks: ChecksView | null;
  groups: MarkingGroup[];
  finishesAt: string;
  homeUntil: string;
}) {
  const router = useRouter();
  const saved = view.deadline ? utcToLondonParts(view.deadline) : { date: "", time: "" };
  const [mode, setMode] = useState<MarkingMode>(view.mode);
  const [date, setDate] = useState(saved.date);
  const [time, setTime] = useState(saved.time);
  const [busy, setBusy] = useState(false);
  const [dialog, setDialog] = useState<Dialog | null>(null);
  const [dialogError, setDialogError] = useState<string | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const opened = view.openedAt !== null;
  const closed = view.closedAt !== null;
  // 3B Task 10: an approved exam's marking cannot be reopened until an admin withdraws the approval.
  const approved = checks?.approved === true;

  function show(d: Dialog) {
    setDialogError(null);
    setNotice(null);
    setDialog(d);
  }

  /** Runs an action; a success closes the dialog and refreshes the page, a failure shows where it was asked. */
  async function run(action: () => Promise<MarkingActionResult>, inDialog: boolean) {
    setBusy(true);
    const res = await action().catch((): MarkingActionResult => ({ ok: false, message: GENERIC }));
    setBusy(false);
    if (res.ok) {
      setDialog(null);
      setNotice(res.message);
      router.refresh();
    } else if (!inDialog && res.reasonRequired) {
      show("deadline");
    } else if (inDialog) {
      setDialogError(res.message);
    } else {
      setFormError(res.message);
    }
  }

  const saveSettings = (reason?: string) =>
    run(() => saveMarkingSettingsAction(examId, { mode, deadlineDate: date, deadlineTime: time, reason }), reason !== undefined);

  function onSave(e: React.FormEvent) {
    e.preventDefault();
    setFormError(null);
    setNotice(null);
    if ((date === "") !== (time === "")) return setFormError("Enter the deadline as a date and a time, or leave both empty.");
    // Once marking has opened a new deadline needs a reason: ask for it first.
    if (opened && (date !== saved.date || time !== saved.time)) return show("deadline");
    void saveSettings();
  }

  return (
    <Card title="Marking">
      {notice && (
        <div role="status" className="mb-3 rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">
          {notice}
        </div>
      )}
      <p data-testid="marking-status" className="text-sm text-slate-700">
        {!opened ? (
          <>
            <Badge tone="slate">Not open</Badge>
            <span className="ml-2">Marking has not opened for this exam.</span>
          </>
        ) : approved ? (
          <>
            <Badge tone="green">Approved</Badge>
            <span className="ml-2">
              This exam&apos;s marking is approved. Marking closed on {formatLondon(view.closedAt ?? "")} (UK time), and nothing about it can
              change until an admin withdraws the approval.
            </span>
          </>
        ) : closed ? (
          <>
            <Badge tone="amber">Closed</Badge>
            <span className="ml-2">Marking closed on {formatLondon(view.closedAt ?? "")} (UK time).</span>
          </>
        ) : (
          <>
            <Badge tone="green">Open</Badge>
            <span className="ml-2">Marking opened on {formatLondon(view.openedAt ?? "")} (UK time).</span>
          </>
        )}
      </p>

      <form onSubmit={onSave} aria-label="Marking settings" className="mt-4 space-y-4">
        <fieldset>
          <legend className="text-sm font-medium text-slate-800">How it is marked</legend>
          <div className="mt-1 flex flex-wrap gap-4 text-sm">
            {(["whole", "by_question"] as const).map((m) => (
              <label key={m} className="flex items-center gap-2">
                <input type="radio" name="marking-mode" value={m} checked={mode === m} disabled={opened || busy} onChange={() => setMode(m)} />
                {m === "whole" ? "Whole script" : "By question"}
              </label>
            ))}
          </div>
          {opened && <p className="mt-1 text-xs text-slate-500">This cannot change once marking has opened.</p>}
          {mode === "by_question" && (
            <div className="mt-2 text-sm text-slate-700">
              {groups.length === 0 ? (
                <p>There are no question groups yet. Add them under Questions and mark scheme.</p>
              ) : (
                <ul className="list-inside list-disc">
                  {groups.map((g) => (
                    <li key={g.id}>
                      {g.label}: {g.questions.length === 0 ? "no questions" : `${g.questions.length === 1 ? "question" : "questions"} ${g.questions.join(", ")}`}
                    </li>
                  ))}
                </ul>
              )}
              <p className="mt-1 text-xs text-slate-500">Each group is marked as a separate piece, possibly by a different marker.</p>
            </div>
          )}
        </fieldset>

        <fieldset>
          <legend className="text-sm font-medium text-slate-800">Marking deadline (UK time)</legend>
          <div className="flex flex-wrap gap-3">
            <label className="block text-sm">
              <span className="sr-only">Deadline date</span>
              <input type="date" value={date} disabled={busy} onChange={(e) => setDate(e.target.value)} className={FIELD} />
            </label>
            <label className="block text-sm">
              <span className="sr-only">Deadline time</span>
              <input type="time" value={time} disabled={busy} onChange={(e) => setTime(e.target.value)} className={FIELD} />
            </label>
          </div>
          <p className="mt-1 text-xs text-slate-500">
            After the exam finishes ({formatLondon(finishesAt)}). Leave both empty for no deadline.
            {opened && " A change needs a reason."}
          </p>
        </fieldset>

        {formError && (
          <p role="alert" className="text-sm text-red-700">
            {formError}
          </p>
        )}
        <button type="submit" disabled={busy} className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60">
          Save settings
        </button>
      </form>

      <ChecksSettings examId={examId} checks={checks} />

      <div className="mt-6 border-t border-slate-100 pt-4">
        <h3 className="text-sm font-semibold text-slate-800">{opened ? "Progress" : "Before marking opens"}</h3>
        <ul data-testid="marking-checks" className="mt-2 list-inside list-disc space-y-1 text-sm text-slate-700">
          {markingChecks(view, homeUntil).map((line) => (
            <li key={line}>{line}</li>
          ))}
        </ul>
        <div className="mt-4 flex flex-wrap gap-2">
          {!opened && (
            <button type="button" disabled={busy} onClick={() => show("open")} className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
              Open marking
            </button>
          )}
          {opened && !closed && (
            <button type="button" disabled={busy} onClick={() => show("close")} className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50">
              Close marking
            </button>
          )}
          {opened && closed && !approved && (
            <button type="button" disabled={busy} onClick={() => show("reopen")} className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50">
              Reopen marking
            </button>
          )}
          {opened && (
            <Link
              href={`/admin/marking/${examId}/approval`}
              className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-800 hover:bg-slate-50"
            >
              {approved ? "Approved" : "Approve marking"}
            </Link>
          )}
        </div>
      </div>

      {dialog === "open" && (
        <ConfirmDialog title="Open marking?" confirmLabel="Open marking" tone="primary" busy={busy} onConfirm={() => run(() => openMarkingAction(examId), true)} onCancel={() => setDialog(null)}>
          <p className="text-sm text-slate-700">
            Verified scripts are handed out to markers as they become ready. Once marking has opened, how the exam is marked cannot change, and questions can only be added.
          </p>
          {dialogError && (
            <p role="alert" className="mt-3 text-sm text-red-700">
              {dialogError}
            </p>
          )}
        </ConfirmDialog>
      )}
      {dialog === "close" && (
        <ReasonDialog title="Close marking?" confirmLabel="Close marking" tone="danger" busy={busy} error={dialogError} onConfirm={(reason) => run(() => closeMarkingAction(examId, reason), true)} onCancel={() => setDialog(null)}>
          <p className="text-sm text-slate-700">Markers can no longer take scripts, save marks or submit for this exam. Nothing is ended or deleted, and you can reopen it.</p>
        </ReasonDialog>
      )}
      {dialog === "reopen" && (
        <ReasonDialog title="Reopen marking?" confirmLabel="Reopen marking" busy={busy} error={dialogError} onConfirm={(reason) => run(() => reopenMarkingAction(examId, reason), true)} onCancel={() => setDialog(null)}>
          <p className="text-sm text-slate-700">Markers can take scripts and save marks again.</p>
        </ReasonDialog>
      )}
      {dialog === "deadline" && (
        <ReasonDialog title="Change the marking deadline?" confirmLabel="Save settings" busy={busy} error={dialogError} onConfirm={(reason) => saveSettings(reason)} onCancel={() => setDialog(null)}>
          <p className="text-sm text-slate-700">Marking has opened, so the change is recorded with your reason.</p>
        </ReasonDialog>
      )}
    </Card>
  );
}
