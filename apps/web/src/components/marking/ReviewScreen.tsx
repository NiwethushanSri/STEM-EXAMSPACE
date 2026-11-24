"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useId, useMemo, useState, useTransition, type ReactNode } from "react";
import { acceptReview, sendBack, setFinalMarks, settleReview, type ReviewActionResult } from "@/app/marking/review/actions";
import { Badge } from "@/components/AppShell";
import { ConfirmDialog } from "@/components/accounts/ConfirmDialog";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import { AnnotationLayer } from "@/components/marking/AnnotationLayer";
import { PagesViewer } from "@/components/marking/PagesViewer";
import { FOCUS } from "@/components/marking/ToolBar";
import { reasonProblem } from "@/lib/exception-queue";
import { totalText } from "@/lib/marking-feedback";
import { unitTotal } from "@/lib/marking-marks";
import {
  noteProblem,
  PARTY_TEXT,
  readMarks,
  reviewRows,
  type MarkBox,
  type OpenedReview,
  type ReviewKind,
  type ReviewMark,
  type ReviewMarking,
  typedMarks,
} from "@/lib/marking-review";
import { formatMark } from "@/lib/marking-screen";

const BUTTON = `inline-flex min-h-11 items-center justify-center rounded px-4 text-sm font-medium disabled:cursor-not-allowed disabled:opacity-50 ${FOCUS}`;
const PRIMARY = `${BUTTON} bg-blue-600 text-white hover:bg-blue-700`;
const QUIET = `${BUTTON} border border-slate-300 bg-white text-slate-900 hover:bg-slate-50`;
const CELL = "py-2 pr-3";
const FIELD = `min-h-11 rounded border border-slate-300 bg-white px-2 py-1.5 text-sm ${FOCUS}`;

const KIND_TEXT: Record<ReviewKind, string> = {
  difference: "Marks that differ",
  paused_marker: "Paused marker's script",
  sample: "Your sample",
};

type Layer = "first" | "second" | "none";
type Dialog = { kind: "first_stands" | "second_stands" } | { kind: "accept" } | { kind: "send_back" };
type Form = "lead_marks" | "final";

/**
 * One review of the lead marker (or an admin), full screen as the marking screen: from 1,200 px the marks table, the
 * pages and the actions side by side; narrower, the pages beside one column with the table above the actions. The pages
 * come through PagesViewer with the first or the second marker's marks laid over them, read only, or none. The table has
 * each question's maximum, both markers' marks and the final mark, "Different" on each question outside the tolerance,
 * and the totals. Each marker's private note to the lead is shown. The actions follow the kind: marks that differ are
 * settled (first marks stand, second marks stand, or the lead's own marks); a paused marker's script or one of the
 * routine sample is accepted, has a final mark changed, or is sent back. Each asks for a reason. Nothing on it names
 * the candidate: the script and index numbers, and the markers' names.
 */
export function ReviewScreen({ data, back }: { data: OpenedReview; back: string }) {
  const router = useRouter();
  const { review, unit, first, second } = data;
  const [layer, setLayer] = useState<Layer>("first");
  const [dialog, setDialog] = useState<Dialog | null>(null);
  const [form, setForm] = useState<Form | null>(null);
  /** What the page's own checks found, shown in the open dialog or form. */
  const [problem, setProblem] = useState<string | null>(null);
  /** The server's refusal, shown with Reload. */
  const [refusal, setRefusal] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const [pending, start] = useTransition();

  const rows = reviewRows(data.compare, data.final);
  const leaves = data.questions.filter((q) => q.leaf);
  const totals = useMemo(() => {
    const qs = data.questions.map((q) => ({ id: q.id, parent_id: q.parentId, max_mark: q.maxMark, option_group_id: q.optionGroupId }));
    const og = data.optionGroups;
    const finalMarks = Object.fromEntries(data.final.map((f) => [f.questionId, { mark: f.mark, na: f.na }]));
    const t = unitTotal(qs, finalMarks, og, false);
    return { max: t.max, final: data.final.length > 0 ? t.total : null };
  }, [data.questions, data.optionGroups, data.final]);
  /** What "Change a final mark" starts from: the final marks, or the first marks while there are none. */
  const baseline: ReviewMark[] = data.final.length > 0 ? data.final : first.marks;
  /** A sample's final marks can be changed only once its script is checked (it has final marks then). */
  const canChange = review.kind === "paused_marker" || data.final.length > 0;

  const shown: ReviewMarking | null = layer === "first" ? first : layer === "second" ? second : null;
  const overlay = (pageId: string) =>
    shown ? <AnnotationLayer annotations={shown.annotations.filter((a) => a.page_id === pageId)} readOnly /> : null;

  /** A new dialog or form, and Reload, start with no old refusal or problem shown (Ruling R18). */
  const clear = () => {
    setProblem(null);
    setRefusal(null);
  };
  const openDialog = (d: Dialog) => {
    clear();
    setDialog(d);
  };
  const openForm = (f: Form) => {
    clear();
    setForm(f);
  };
  const closeAll = () => {
    clear();
    setDialog(null);
    setForm(null);
  };
  const reload = () => {
    clear();
    router.refresh();
  };
  /** After the server answered: a refusal closes a dialog and is shown with Reload (a marker may have changed the script
   * meanwhile), while an open form stays open with the marks the lead typed; a success says what happened, and the page
   * is read again. */
  const finish = (r: ReviewActionResult, said: string) => {
    setDialog(null);
    if (!r.ok) return setRefusal(r.message);
    closeAll();
    setDone(r.message ?? said);
    router.refresh();
  };
  const run = (action: () => Promise<ReviewActionResult>, said: string) =>
    start(async () => {
      clear();
      finish(await action(), said);
    });

  const onSettle = (outcome: "first_stands" | "second_stands", reason: string) => {
    if (!second) return;
    run(() => settleReview(review.id, outcome, first.rev, second.rev, reason), outcome === "first_stands" ? "Settled. The first marks stand." : "Settled. The second marks stand.");
  };

  const table = (
    <section aria-label="Marks" className="space-y-3 p-4">
      <p className="text-sm text-slate-700">
        First marker: <span className="font-medium text-slate-900">{first.markerName}</span>
        {second && (
          <>
            <br />
            Second marker: <span className="font-medium text-slate-900">{second.markerName}</span>
          </>
        )}
      </p>
      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-slate-200 text-slate-600">
            <tr>
              <th scope="col" className={`${CELL} font-medium`}>
                Question
              </th>
              <th scope="col" className={`${CELL} font-medium`}>
                Maximum
              </th>
              <th scope="col" className={`${CELL} font-medium`}>
                First
              </th>
              {second && (
                <th scope="col" className={`${CELL} font-medium`}>
                  Second
                </th>
              )}
              <th scope="col" className={`${CELL} font-medium`}>
                Final
              </th>
              <th scope="col" className="py-2 font-medium">
                <span className="sr-only">Outside the tolerance</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={data.compare.questions[i].questionId} data-testid="review-row" className="border-b border-slate-100">
                <th scope="row" className={`${CELL} font-medium text-slate-900`}>
                  {r.label}
                </th>
                <td className={`${CELL} tabular-nums text-slate-700`}>{formatMark(r.max)}</td>
                <td className={`${CELL} tabular-nums text-slate-800`}>{r.first}</td>
                {second && <td className={`${CELL} tabular-nums text-slate-800`}>{r.second}</td>}
                <td className={`${CELL} tabular-nums text-slate-800`}>{r.final}</td>
                <td className="py-2">{r.out && <Badge tone="amber">Different</Badge>}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr>
              <th scope="row" className={`${CELL} font-semibold text-slate-900`}>
                Total
              </th>
              <td className={`${CELL} font-semibold tabular-nums text-slate-700`}>{formatMark(totals.max)}</td>
              <td data-testid="review-first-total" className={`${CELL} font-semibold tabular-nums text-slate-900`}>
                {totalText(first.total, null)}
              </td>
              {second && (
                <td data-testid="review-second-total" className={`${CELL} font-semibold tabular-nums text-slate-900`}>
                  {totalText(second.total, null)}
                </td>
              )}
              <td className={`${CELL} font-semibold tabular-nums text-slate-900`}>{totalText(totals.final, null)}</td>
              <td />
            </tr>
          </tfoot>
        </table>
      </div>
    </section>
  );

  const notes = (
    <section aria-label="Notes to the lead marker" className="space-y-2">
      <h2 className="text-sm font-semibold text-slate-900">Notes to the lead marker</h2>
      <Note who={`First marker (${first.markerName})`} text={first.leadNote} />
      {second && <Note who={`Second marker (${second.markerName})`} text={second.leadNote} />}
    </section>
  );

  let actions: ReactNode;
  if (done) {
    actions = (
      <div className="space-y-3">
        <p role="status" className="rounded border border-green-200 bg-green-50 px-3 py-2 text-sm text-green-900">
          {done}
        </p>
        <Link href={back} className={`${PRIMARY} w-full`}>
          Back to Review
        </Link>
      </div>
    );
  } else if (!review.open) {
    actions = <p className="text-sm text-slate-700">This review is closed.</p>;
  } else if (form) {
    actions = (
      <MarksForm
        title={form === "lead_marks" ? "Set my own marks" : "Change a final mark"}
        questions={leaves}
        start={form === "final" ? baseline : []}
        busy={pending}
        error={problem}
        onCancel={closeAll}
        onSave={(boxes, typed, reason) => {
          setProblem(null);
          const bad = reasonProblem(reason, true);
          if (bad) return setProblem(bad);
          const read = readMarks(leaves, boxes);
          if (!read.ok) return setProblem(read.message);
          if (form === "lead_marks") {
            if (!second) return;
            return run(() => settleReview(review.id, "lead_marks", first.rev, second.rev, reason, read.marks), "Settled. Your marks stand.");
          }
          const sending = typedMarks(read.marks, typed);
          if (sending.length === 0) return setProblem("Change at least one mark first.");
          // One action (Rulings R17, R18): the review is accepted first, then the marks change, so a paused marker's
          // script is checked and a sample's review closes.
          run(() => setFinalMarks(unit.id, sending, reason, review.id), "Final marks changed.");
        }}
      />
    );
  } else if (review.kind === "difference") {
    actions = (
      <div className="flex flex-col gap-2">
        <button type="button" className={PRIMARY} disabled={pending || !second} onClick={() => openDialog({ kind: "first_stands" })}>
          First marks stand
        </button>
        <button type="button" className={PRIMARY} disabled={pending || !second} onClick={() => openDialog({ kind: "second_stands" })}>
          Second marks stand
        </button>
        <button type="button" className={QUIET} disabled={pending || !second} onClick={() => openForm("lead_marks")}>
          Set my own marks
        </button>
      </div>
    );
  } else {
    actions = (
      <div className="flex flex-col gap-2">
        <button type="button" className={PRIMARY} disabled={pending} onClick={() => openDialog({ kind: "accept" })}>
          Accept
        </button>
        {canChange ? (
          <button type="button" className={QUIET} disabled={pending} onClick={() => openForm("final")}>
            Change a final mark
          </button>
        ) : (
          <p className="text-sm text-slate-600">This script is not checked yet, so its final marks cannot be changed.</p>
        )}
        <button type="button" className={QUIET} disabled={pending} onClick={() => openDialog({ kind: "send_back" })}>
          Send back
        </button>
      </div>
    );
  }

  return (
    <div className="flex h-dvh flex-col bg-slate-100 text-slate-900">
      <header className="flex flex-wrap items-center gap-x-4 gap-y-2 border-b border-slate-200 bg-white px-3 py-2">
        <Link href={back} aria-label="Back to Review" className={`${BUTTON} -ml-1 px-2 text-blue-800 hover:bg-slate-50`}>
          <svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M15 18l-6-6 6-6" />
          </svg>
          Review
        </Link>
        <div className="min-w-0">
          <h1 className="truncate text-sm font-semibold text-slate-900">{unit.examTitle}</h1>
          <p className="truncate text-sm text-slate-600">
            {unit.paper}
            {unit.groupLabel ? ` · ${unit.groupLabel}` : ""}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2 text-sm">
          <span className="text-slate-600">Script</span>
          <span className="font-semibold tabular-nums text-slate-900">{unit.scriptNumber}</span>
          <span className="text-slate-600">Index</span>
          <span data-testid="index-number" className="font-semibold tabular-nums text-slate-900">
            {unit.indexNumber ?? "–"}
          </span>
          <Badge tone={review.kind === "difference" ? "amber" : "slate"}>{KIND_TEXT[review.kind]}</Badge>
        </div>
        {review.party && (
          <p role="note" className="rounded border border-amber-200 bg-amber-50 px-2 py-1 text-sm text-amber-900">
            {PARTY_TEXT}
          </p>
        )}
      </header>

      <div className="grid min-h-0 flex-1 grid-cols-[minmax(0,1fr)_320px] grid-rows-[minmax(0,1fr)] min-[1200px]:grid-cols-[340px_minmax(0,1fr)_320px]">
        <main className="col-start-1 row-start-1 min-h-0 overflow-y-auto p-4 min-[1200px]:col-start-2">
          <fieldset className="mb-3 flex flex-wrap items-center gap-2">
            <legend className="sr-only">Marks on the page</legend>
            <LayerOption value="first" layer={layer} onLayer={setLayer} label="First marker's marks" />
            {second && <LayerOption value="second" layer={layer} onLayer={setLayer} label="Second marker's marks" />}
            <LayerOption value="none" layer={layer} onLayer={setLayer} label="No marks" />
          </fieldset>
          <PagesViewer unitId={unit.id} pages={data.pages} overlay={overlay} />
        </main>
        {/* Narrower than 1,200 px, one column: the table above the actions. From 1,200 px each is its own area. */}
        <div className="col-start-2 row-start-1 min-h-0 overflow-y-auto border-l border-slate-200 bg-white min-[1200px]:contents">
          <aside className="min-[1200px]:col-start-1 min-[1200px]:row-start-1 min-[1200px]:min-h-0 min-[1200px]:overflow-y-auto min-[1200px]:border-r min-[1200px]:border-slate-200 min-[1200px]:bg-white">
            {table}
          </aside>
          <aside
            aria-label="Decide"
            className="space-y-5 border-t border-slate-200 p-4 min-[1200px]:col-start-3 min-[1200px]:row-start-1 min-[1200px]:min-h-0 min-[1200px]:overflow-y-auto min-[1200px]:border-l min-[1200px]:border-t-0 min-[1200px]:bg-white"
          >
            {notes}
            {actions}
            {refusal && !done && <Refusal message={refusal} onReload={reload} />}
          </aside>
        </div>
      </div>

      {dialog && (dialog.kind === "first_stands" || dialog.kind === "second_stands") && (
        <ReasonDialog
          title={dialog.kind === "first_stands" ? "First marks stand" : "Second marks stand"}
          confirmLabel={dialog.kind === "first_stands" ? "First marks stand" : "Second marks stand"}
          busy={pending}
          error={problem}
          onCancel={closeAll}
          onConfirm={(reason) => onSettle(dialog.kind as "first_stands" | "second_stands", reason)}
        >
          <p className="text-sm text-slate-700">
            {dialog.kind === "first_stands" ? `${first.markerName}'s marks become the final marks.` : `${second?.markerName ?? "The second marker"}'s marks become the final marks.`} Neither
            marking changes.
          </p>
        </ReasonDialog>
      )}
      {dialog?.kind === "accept" && (
        <AcceptDialog
          paused={review.kind === "paused_marker"}
          busy={pending}
          onCancel={closeAll}
          onConfirm={(reason) => run(() => acceptReview(review.id, reason || undefined), "Accepted.")}
        />
      )}
      {dialog?.kind === "send_back" && (
        <SendBackDialog
          paused={review.kind === "paused_marker"}
          markerName={first.markerName}
          busy={pending}
          error={problem}
          onError={setProblem}
          onCancel={closeAll}
          onConfirm={(to, note, reason) => run(() => sendBack(unit.id, to, note, reason), "Sent back.")}
        />
      )}
    </div>
  );
}

function Note({ who, text }: { who: string; text: string | null }) {
  return (
    <div className="rounded border border-slate-200 bg-slate-50 p-3 text-sm">
      <h3 className="font-medium text-slate-900">{who}</h3>
      <p className="mt-1 whitespace-pre-wrap text-slate-700">{text ?? "No note."}</p>
    </div>
  );
}

function LayerOption({ value, layer, onLayer, label }: { value: Layer; layer: Layer; onLayer: (l: Layer) => void; label: string }) {
  const checked = layer === value;
  return (
    <label
      className={`inline-flex min-h-11 cursor-pointer items-center gap-2 rounded border px-3 text-sm font-medium has-[:focus-visible]:outline has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-blue-600 ${
        checked ? "border-blue-600 bg-blue-50 text-blue-800" : "border-slate-300 bg-white text-slate-800"
      }`}
    >
      <input type="radio" name="review-layer" value={value} checked={checked} onChange={() => onLayer(value)} className="sr-only" />
      {label}
    </label>
  );
}

/** A refusal, with Reload: the page is read again from the database (a marker may have changed the script). */
function Refusal({ message, onReload }: { message: string; onReload: () => void }) {
  return (
    <div role="alert" className="space-y-2 rounded border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
      <p>{message}</p>
      <button type="button" className={QUIET} onClick={onReload}>
        Reload
      </button>
    </div>
  );
}

/** A mark box and NR per question, then a reason. `start`: the marks the boxes start with, read from the page as it is
 * now, so a box the lead has not typed into follows the page when it is read again; a box they typed into keeps what
 * they typed (Ruling R18), through a refusal and Reload. onSave gets every box and the questions typed into. */
function MarksForm({
  title,
  questions,
  start,
  busy,
  error,
  onSave,
  onCancel,
}: {
  title: string;
  questions: OpenedReview["questions"];
  start: ReviewMark[];
  busy: boolean;
  error: string | null;
  onSave: (boxes: Record<string, MarkBox>, typed: ReadonlySet<string>, reason: string) => void;
  onCancel: () => void;
}) {
  const reasonId = useId();
  const [typed, setTyped] = useState<Record<string, MarkBox>>({});
  const [reason, setReason] = useState("");
  const from: Record<string, MarkBox> = Object.fromEntries(
    start.map((m) => [m.questionId, { text: m.na || m.mark === null ? "" : formatMark(m.mark), na: m.na }]),
  );
  const boxes: Record<string, MarkBox> = { ...from, ...typed };
  const set = (id: string, box: MarkBox) => setTyped((b) => ({ ...b, [id]: box }));
  return (
    <form
      className="space-y-4"
      onSubmit={(e) => {
        e.preventDefault();
        onSave(boxes, new Set(Object.keys(typed)), reason.trim());
      }}
    >
      <h2 className="text-sm font-semibold text-slate-900">{title}</h2>
      <ul className="space-y-2">
        {questions.map((q) => {
          const box = boxes[q.id] ?? { text: "", na: false };
          return (
            <li key={q.id} className="flex flex-wrap items-center gap-2 text-sm">
              <label htmlFor={`mark-${q.id}`} className="w-20 font-medium text-slate-900">
                {q.label}
              </label>
              <input
                id={`mark-${q.id}`}
                inputMode="decimal"
                value={box.text}
                disabled={box.na}
                onChange={(e) => set(q.id, { text: e.target.value, na: false })}
                className={`${FIELD} w-20 tabular-nums`}
                aria-describedby={`max-${q.id}`}
              />
              <span id={`max-${q.id}`} className="text-slate-600">
                out of {formatMark(q.maxMark ?? 0)}
              </span>
              <label className="ml-auto inline-flex min-h-11 items-center gap-2 text-slate-800">
                <input type="checkbox" checked={box.na} onChange={(e) => set(q.id, { text: "", na: e.target.checked })} className="h-5 w-5" />
                NR
              </label>
            </li>
          );
        })}
      </ul>
      <label htmlFor={reasonId} className="block text-sm">
        <span className="font-medium text-slate-700">Reason</span>
        <textarea id={reasonId} value={reason} maxLength={300} rows={3} onChange={(e) => setReason(e.target.value)} className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm" />
        <span className="text-xs text-slate-500">3 to 300 characters. It goes into the audit log.</span>
      </label>
      {error && (
        <p role="alert" className="text-sm text-red-700">
          {error}
        </p>
      )}
      <div className="flex gap-2">
        <button type="submit" className={PRIMARY} disabled={busy}>
          {busy ? "Saving…" : "Save these marks"}
        </button>
        <button type="button" className={QUIET} disabled={busy} onClick={onCancel}>
          Cancel
        </button>
      </div>
    </form>
  );
}

/** Accept: an optional reason (3 to 300 characters when given). */
function AcceptDialog({
  paused,
  busy,
  onConfirm,
  onCancel,
}: {
  paused: boolean;
  busy: boolean;
  onConfirm: (reason: string) => void;
  onCancel: () => void;
}) {
  const id = useId();
  const [reason, setReason] = useState("");
  const [problem, setProblem] = useState<string | null>(null);
  return (
    <ConfirmDialog
      title="Accept this script"
      confirmLabel="Accept"
      tone="primary"
      busy={busy}
      onCancel={() => {
        if (!busy) onCancel();
      }}
      onConfirm={() => {
        const p = reasonProblem(reason, false);
        setProblem(p);
        if (!p) onConfirm(reason.trim());
      }}
    >
      <div className="space-y-3 text-sm">
        <p className="text-slate-700">{paused ? "The script is checked on the first marks." : "The review closes. The script and its marks stay as they are."}</p>
        <label htmlFor={id} className="block font-medium text-slate-800">
          Reason (optional)
        </label>
        <textarea id={id} value={reason} maxLength={300} rows={2} onChange={(e) => setReason(e.target.value)} className="w-full rounded border border-slate-300 px-3 py-2" />
        <p className="text-xs text-slate-500">If you give one, 3 to 300 characters.</p>
        {problem && (
          <p role="alert" className="text-red-700">
            {problem}
          </p>
        )}
      </div>
    </ConfirmDialog>
  );
}

/** Send back: to the same marker, whose marking opens again with the note, or to another; only to another for a paused
 * marker's script. The note (3 to 1,000 characters) and a reason are checked here first. */
function SendBackDialog({
  paused,
  markerName,
  busy,
  error,
  onError,
  onConfirm,
  onCancel,
}: {
  paused: boolean;
  markerName: string;
  busy: boolean;
  error: string | null;
  onError: (message: string | null) => void;
  onConfirm: (to: "same" | "other", note: string, reason: string) => void;
  onCancel: () => void;
}) {
  const noteId = useId();
  const [to, setTo] = useState<"same" | "other">(paused ? "other" : "same");
  const [note, setNote] = useState("");
  return (
    <ReasonDialog
      title="Send back"
      confirmLabel="Send back"
      busy={busy}
      error={error}
      onCancel={onCancel}
      onConfirm={(reason) => {
        const bad = noteProblem(note, true);
        if (bad) return onError(bad);
        onConfirm(to, note.trim(), reason);
      }}
    >
      <fieldset className="space-y-2 text-sm">
        <legend className="font-medium text-slate-700">Who marks it again</legend>
        {!paused && (
          <label className="flex min-h-11 items-center gap-2">
            <input type="radio" name="send-back-to" checked={to === "same"} onChange={() => setTo("same")} className="h-5 w-5" />
            To the same marker ({markerName})
          </label>
        )}
        <label className="flex min-h-11 items-center gap-2">
          <input type="radio" name="send-back-to" checked={to === "other"} onChange={() => setTo("other")} className="h-5 w-5" />
          To another marker
        </label>
      </fieldset>
      <label htmlFor={noteId} className="block text-sm">
        <span className="font-medium text-slate-700">{to === "same" ? "Note to the marker" : "Note for the record (no marker reads it)"}</span>
        <textarea id={noteId} value={note} maxLength={1000} rows={3} onChange={(e) => setNote(e.target.value)} className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm" />
        <span className="text-xs text-slate-500">
          {to === "same" ? "3 to 1,000 characters. The marker reads it on the script." : "3 to 1,000 characters. It is kept with the marking that is set aside."}
        </span>
      </label>
    </ReasonDialog>
  );
}
