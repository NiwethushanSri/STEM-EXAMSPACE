"use client";

import { useId, useState } from "react";
import { FOCUS } from "@/components/marking/ToolBar";
import { validMark, type MarkEntry } from "@/lib/marking-marks";
import { formatMark, markControls, type ScreenQuestion } from "@/lib/marking-screen";

/** The longest note to the lead marker the database keeps. */
export const LEAD_NOTE_MAX = 1000;
/** The id of the mark box, which a number key focuses for a question out of more than 9 (the box is then shown). */
export const MARK_INPUT_ID = "marking-mark-input";

const BTN = `inline-flex min-h-11 min-w-11 items-center justify-center rounded border px-2 text-sm font-semibold tabular-nums disabled:cursor-not-allowed disabled:opacity-40 ${FOCUS}`;
const OFF = "border-slate-300 bg-white text-slate-900 hover:bg-slate-50";
const ON = "border-blue-700 bg-blue-600 text-white";

const marksWord = (n: number) => `${formatMark(n)} ${n === 1 ? "mark" : "marks"}`;

/**
 * The right area: the current question, out of its maximum, with its marking points, alternatives and guidance; the
 * mark buttons (up to 21) and, for a question out of more than 9, a number box beside them (the number box alone when
 * there would be more than 21 buttons), "+½" for a question in half marks, "NR"; the mark
 * scheme PDF; and the private note to the lead marker. `disabled` when input has stopped or the piece is read only.
 */
export function MarkPanel({
  question,
  entry,
  onMark,
  disabled,
  note,
  onNote,
  onOpenScheme,
  schemeMessage,
}: {
  question: ScreenQuestion | null;
  entry: MarkEntry | undefined;
  onMark: (mark: number | null, na: boolean) => void;
  disabled: boolean;
  note: string;
  onNote: (text: string) => void;
  /** Present when the exam has a mark scheme PDF. */
  onOpenScheme: (() => void) | null;
  schemeMessage: string | null;
}) {
  const noteId = useId();
  const helpId = useId();
  const [draft, setDraft] = useState<string | null>(null);
  return (
    <div className="flex h-full flex-col gap-4 overflow-y-auto p-4">
      {question ? (
        <QuestionMarks key={question.id} question={question} entry={entry} onMark={onMark} disabled={disabled} />
      ) : (
        <p className="text-sm text-slate-700">This script has no question to mark.</p>
      )}
      {onOpenScheme && (
        <div>
          <button type="button" onClick={onOpenScheme} className={`min-h-11 w-full rounded border border-slate-300 bg-white px-3 text-sm font-medium text-blue-800 hover:bg-slate-50 ${FOCUS}`}>
            Open the mark scheme PDF
          </button>
          {schemeMessage && (
            <p role="alert" className="mt-1 text-sm text-amber-900">
              {schemeMessage}
            </p>
          )}
        </div>
      )}
      <div className="border-t border-slate-200 pt-4">
        <label htmlFor={noteId} className="block text-sm font-semibold text-slate-900">
          Private note to the lead marker
        </label>
        <textarea
          id={noteId}
          aria-describedby={helpId}
          value={draft ?? note}
          maxLength={LEAD_NOTE_MAX}
          rows={3}
          disabled={disabled}
          onFocus={() => setDraft(note)}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={() => {
            if (draft !== null && draft !== note) onNote(draft);
            setDraft(null);
          }}
          className={`mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm text-slate-900 disabled:bg-slate-50 ${FOCUS}`}
        />
        <p id={helpId} className="mt-1 text-sm text-slate-600">
          Notes you write on the page are shown to the family with the results. This note is not.
        </p>
      </div>
    </div>
  );
}

function QuestionMarks({ question: q, entry, onMark, disabled }: { question: ScreenQuestion; entry: MarkEntry | undefined; onMark: (mark: number | null, na: boolean) => void; disabled: boolean }) {
  const max = q.maxMark ?? 0;
  const { buttons, box } = markControls(max, q.step);
  const current = entry && !entry.na ? entry.mark : null;
  const nr = !!entry?.na;
  const [typed, setTyped] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const problemId = useId();

  const commitTyped = () => {
    if (typed === null) return;
    const text = typed.trim();
    setTyped(null);
    if (text === "") return setProblem(null);
    const value = Number(text);
    if (!validMark(value, max, q.step)) {
      setProblem(`Give a mark from 0 to ${formatMark(max)}${q.step === 0.5 ? ", in half marks" : ", in whole marks"}.`);
      return;
    }
    setProblem(null);
    if (value !== current || nr) onMark(value, false);
  };
  const half = current === null ? 0.5 : current + 0.5;

  return (
    <section aria-labelledby={`${problemId}-h`} className="space-y-3">
      <div>
        <h2 id={`${problemId}-h`} className="text-base font-semibold text-slate-900">
          Question {q.label}
        </h2>
        <p className="text-sm text-slate-700">
          Out of {marksWord(max)}
          {q.step === 0.5 ? ", in half marks" : ""}
          {q.levels ? ". Marked by levels" : ""}
        </p>
        <p className="mt-1 text-sm text-slate-900" aria-live="polite">
          {nr ? "NR: no response" : current === null ? "No mark yet" : `Mark: ${formatMark(current)}`}
        </p>
      </div>

      {buttons && (
        <div className="flex flex-wrap gap-1" role="group" aria-label={`Mark for question ${q.label}`}>
          {buttons.map((v) => (
            <button
              key={v}
              type="button"
              aria-label={marksWord(v)}
              aria-pressed={current === v && !nr}
              disabled={disabled}
              onClick={() => {
                if (current !== v || nr) onMark(v, false);
              }}
              className={`${BTN} ${current === v && !nr ? ON : OFF}`}
            >
              {formatMark(v)}
            </button>
          ))}
        </div>
      )}
      {box && (
        <div>
          <label htmlFor={MARK_INPUT_ID} className="block text-sm font-medium text-slate-800">
            Mark (0 to {formatMark(max)})
          </label>
          <input
            id={MARK_INPUT_ID}
            type="number"
            inputMode="decimal"
            min={0}
            max={max}
            step={q.step}
            disabled={disabled}
            aria-invalid={problem ? true : undefined}
            aria-describedby={problem ? problemId : undefined}
            value={typed ?? (current === null ? "" : String(current))}
            onChange={(e) => setTyped(e.target.value)}
            onBlur={commitTyped}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                commitTyped();
              }
            }}
            className={`mt-1 min-h-11 w-28 rounded border border-slate-300 px-3 text-sm tabular-nums ${FOCUS}`}
          />
          {problem && (
            <p id={problemId} role="alert" className="mt-1 text-sm text-amber-900">
              {problem}
            </p>
          )}
        </div>
      )}

      <div className="flex flex-wrap gap-1">
        {q.step === 0.5 && (
          <button
            type="button"
            aria-label="Add half a mark"
            disabled={disabled || !validMark(half, max, 0.5)}
            onClick={() => onMark(half, false)}
            className={`${BTN} ${OFF}`}
          >
            +½
          </button>
        )}
        <button
          type="button"
          aria-label="NR: no response"
          aria-pressed={nr}
          disabled={disabled}
          onClick={() => (nr ? onMark(null, false) : onMark(null, true))}
          className={`${BTN} ${nr ? ON : OFF} px-3`}
        >
          NR
        </button>
      </div>

      {q.points.length > 0 && (
        <div>
          <h3 className="text-sm font-semibold text-slate-900">Marking points</h3>
          <ul className="mt-1 space-y-1">
            {q.points.map((p) => (
              <li key={p.id} className="rounded border border-slate-200 bg-slate-50 px-2 py-1.5 text-sm text-slate-800">
                <span className="font-semibold">
                  {p.label ? `${p.label} · ` : ""}
                  {p.marksTo !== null ? `${formatMark(p.marks)} to ${formatMark(p.marksTo)} marks` : marksWord(p.marks)}
                </span>
                <span className="block whitespace-pre-wrap">{p.text}</span>
              </li>
            ))}
          </ul>
        </div>
      )}
      {q.alternatives && (
        <div>
          <h3 className="text-sm font-semibold text-slate-900">Also accept</h3>
          <p className="mt-1 whitespace-pre-wrap text-sm text-slate-800">{q.alternatives}</p>
        </div>
      )}
      {q.guidance && (
        <div>
          <h3 className="text-sm font-semibold text-slate-900">Guidance</h3>
          <p className="mt-1 whitespace-pre-wrap text-sm text-slate-800">{q.guidance}</p>
        </div>
      )}
    </section>
  );
}
