"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useId, useState, useTransition } from "react";
import { Badge, Card } from "@/components/AppShell";
import { ConfirmDialog } from "@/components/accounts/ConfirmDialog";
import { DeadlineLine } from "@/components/marking/MarkingProgress";
import { giveBack, nextScript } from "@/app/marking/actions";
import { pieceHoldLine, pieceStateLabel, type MyPiece, type MyWorkExam } from "@/lib/marking-lists";

const BUTTON = "min-h-11 rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50";
const QUIET = "min-h-11 rounded border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";

/** A marker's exams (each with Next script, per question group when marked by question) and the scripts they hold,
 * have in progress or have submitted. The index number is shown; nothing names the candidate. `now` is the server's
 * clock when the page was made. */
export function MyWork({ exams, pieces, now }: { exams: MyWorkExam[]; pieces: MyPiece[]; now: string }) {
  const at = new Date(now);
  return (
    <div className="space-y-6">
      {exams.length === 0 ? (
        <Card title="Exams to mark">
          <p className="text-sm text-slate-600">No exam in your subjects is open for marking yet.</p>
        </Card>
      ) : (
        <div className="grid gap-4 lg:grid-cols-2">
          {exams.map((e) => (
            <ExamCard key={e.examId} exam={e} now={at} />
          ))}
        </div>
      )}
      <YourScripts pieces={pieces} exams={exams} now={at} />
    </div>
  );
}

function ExamCard({ exam, now }: { exam: MyWorkExam; now: Date }) {
  return (
    <Card title={exam.title}>
      <div className="space-y-3" data-testid="marking-exam">
        <p className="text-sm text-slate-600">
          {exam.subject}
          {exam.paper ? ` · ${exam.paper}` : ""}
        </p>
        <DeadlineLine deadline={exam.deadline} overdue={exam.overdue} now={now} />
        {exam.closed ? (
          <p className="text-sm text-slate-700">Marking has closed for this exam.</p>
        ) : exam.mode === "by_question" ? (
          <ul className="divide-y divide-slate-100">
            {exam.groups.map((g) => (
              <li key={g.id} className="flex flex-wrap items-center justify-between gap-3 py-2">
                <span className="text-sm">
                  <span className="font-medium text-slate-900">{g.label}</span>
                  <span className="ml-2 text-slate-600">{g.left} left to mark</span>
                </span>
                <NextButton examId={exam.examId} groupId={g.id} label={`Next script for ${g.label}`} />
              </li>
            ))}
          </ul>
        ) : (
          <div className="flex flex-wrap items-center justify-between gap-3">
            <span className="text-sm text-slate-700">{exam.left} left to mark</span>
            <NextButton examId={exam.examId} groupId={null} label={`Next script for ${exam.title}`} />
          </div>
        )}
      </div>
    </Card>
  );
}

/** "Next script": opens the piece the database hands out, or says why there is none. */
function NextButton({ examId, groupId, label }: { examId: string; groupId: string | null; label: string }) {
  const router = useRouter();
  const [message, setMessage] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <div className="flex flex-col items-end gap-1">
      <button
        type="button"
        aria-label={label}
        className={BUTTON}
        disabled={pending}
        onClick={() =>
          start(async () => {
            setMessage(null);
            const r = await nextScript(examId, groupId);
            if (r.ok) router.push(`/marking/${r.unitId}`);
            else setMessage(r.message);
          })
        }
      >
        {pending ? "Finding a script..." : "Next script"}
      </button>
      <p aria-live="polite" className="text-sm text-slate-700">
        {message}
      </p>
    </div>
  );
}

function YourScripts({ pieces, exams, now }: { pieces: MyPiece[]; exams: MyWorkExam[]; now: Date }) {
  const titles = new Map(exams.map((e) => [e.examId, e.title]));
  const closed = new Set(exams.filter((e) => e.closed).map((e) => e.examId));
  return (
    <Card title="Your scripts">
      {pieces.length === 0 ? (
        <p className="text-sm text-slate-600">You have no scripts yet. Press Next script to start marking.</p>
      ) : (
        <ul className="divide-y divide-slate-100">
          {pieces.map((p) => (
            <PieceRow key={p.unitId} piece={p} examTitle={titles.get(p.examId) ?? ""} closed={closed.has(p.examId)} now={now} />
          ))}
        </ul>
      )}
    </Card>
  );
}

function PieceRow({ piece, examTitle, closed, now }: { piece: MyPiece; examTitle: string; closed: boolean; now: Date }) {
  const [giving, setGiving] = useState(false);
  const state = pieceStateLabel(piece);
  const line = pieceHoldLine(piece, now);
  // A piece on hold, or whose hold ran out, cannot be opened: Next script carries on with it.
  const canOpen = !piece.onHold && piece.state !== "open";
  const canGiveBack = !closed && piece.state !== "submitted";
  return (
    <li data-testid="marking-piece" className="flex flex-wrap items-start justify-between gap-3 py-3 text-sm">
      <div className="space-y-1">
        <p>
          <span className="font-medium text-slate-900">Script {piece.scriptNumber}</span>
          {piece.indexNumber && <span className="ml-2 text-slate-700">Index {piece.indexNumber}</span>}
          {piece.groupLabel && <span className="ml-2 text-slate-600">{piece.groupLabel}</span>}
          <span className="ml-2">
            <Badge tone={piece.onHold ? "amber" : piece.state === "submitted" ? "green" : "blue"}>{state}</Badge>
          </span>
        </p>
        <p className="text-slate-600">{examTitle}</p>
        {line && <p className="text-slate-700">{line}</p>}
        {piece.pagesChanged && (
          <p role="note" className="rounded border border-amber-200 bg-amber-50 px-2 py-1 text-amber-900">
            Pages of this script changed. Check your marks and submit again.
          </p>
        )}
      </div>
      <div className="flex gap-2">
        {canOpen && (
          <Link href={`/marking/${piece.unitId}`} className={`${QUIET} inline-flex items-center`} aria-label={`Open script ${piece.scriptNumber}`}>
            Open
          </Link>
        )}
        {canGiveBack && (
          <button type="button" className={QUIET} onClick={() => setGiving(true)} aria-label={`Give back script ${piece.scriptNumber}`}>
            Give back
          </button>
        )}
      </div>
      {giving && <GiveBackDialog piece={piece} onClose={() => setGiving(false)} />}
    </li>
  );
}

/** Giving a script back: an optional reason, then it is free for others to mark. */
function GiveBackDialog({ piece, onClose }: { piece: MyPiece; onClose: () => void }) {
  const router = useRouter();
  const id = useId();
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <ConfirmDialog
      title={`Give back script ${piece.scriptNumber}`}
      confirmLabel="Give back"
      tone="primary"
      busy={pending}
      onCancel={() => {
        if (!pending) onClose();
      }}
      onConfirm={() =>
        start(async () => {
          const r = await giveBack(piece.unitId, reason);
          if (!r.ok) return setError(r.message);
          onClose();
          router.refresh();
        })
      }
    >
      <div className="space-y-3 text-sm">
        <p className="text-slate-700">Another marker can then mark it. What you have marked is set aside.</p>
        <label htmlFor={id} className="block font-medium text-slate-800">
          Reason (optional)
        </label>
        <textarea id={id} value={reason} maxLength={300} rows={2} onChange={(e) => setReason(e.target.value)} className="w-full rounded border border-slate-300 px-3 py-2" />
        <p className="text-xs text-slate-500">If you give one, 3 to 300 characters.</p>
        {error && (
          <p role="alert" className="text-red-700">
            {error}
          </p>
        )}
      </div>
    </ConfirmDialog>
  );
}
