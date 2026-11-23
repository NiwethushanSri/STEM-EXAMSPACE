"use client";

import { useEffect, useId, useState } from "react";
import { markingFeedback, type FeedbackResult } from "@/app/marking/actions";
import { Badge } from "@/components/AppShell";
import { FOCUS } from "@/components/marking/ToolBar";
import { FEEDBACK_FAILED, FEEDBACK_HEADING, feedbackRows, totalText } from "@/lib/marking-feedback";

const QUIET = `inline-flex min-h-11 items-center justify-center rounded border border-slate-300 bg-white px-4 text-sm font-medium text-slate-900 hover:bg-slate-50 ${FOCUS}`;
const CELL = "py-2 pr-4";

/**
 * After a practice script, or a seeded script marked outside tolerance: the marker's marks beside the lead marker's
 * (marking_feedback), "Different" on each question outside the tolerance, both totals and the lead marker's note. It
 * takes the place of the page on the marking screen, and nothing on it can be changed. It names nobody.
 */
export function FeedbackPanel({ markingId }: { markingId: string }) {
  const headingId = useId();
  const [result, setResult] = useState<FeedbackResult | null>(null);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let live = true;
    markingFeedback(markingId).then(
      (r) => live && setResult(r),
      () => live && setResult({ ok: false, message: FEEDBACK_FAILED }),
    );
    return () => {
      live = false;
    };
  }, [markingId, attempt]);

  if (!result) {
    return (
      <p role="status" className="text-sm text-slate-700">
        Loading the lead marker&apos;s marks...
      </p>
    );
  }
  if (!result.ok) {
    return (
      <div className="space-y-3">
        <p role="alert" className="text-sm text-amber-900">
          {result.message}
        </p>
        <button
          type="button"
          className={QUIET}
          onClick={() => {
            setResult(null);
            setAttempt((n) => n + 1);
          }}
        >
          Try again
        </button>
      </div>
    );
  }

  const f = result.feedback;
  const rows = feedbackRows(f);
  return (
    <section aria-labelledby={headingId} data-testid="feedback-panel" className="space-y-4">
      <h2 id={headingId} className="text-base font-semibold text-slate-900">
        {FEEDBACK_HEADING[f.use]}
      </h2>
      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-slate-200 text-slate-600">
            <tr>
              <th scope="col" className={`${CELL} font-medium`}>
                Question
              </th>
              <th scope="col" className={`${CELL} font-medium`}>
                Your mark
              </th>
              <th scope="col" className={`${CELL} font-medium`}>
                Lead marker&apos;s mark
              </th>
              <th scope="col" className="py-2 font-medium">
                <span className="sr-only">Outside the tolerance</span>
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={f.questions[i].questionId} data-testid="feedback-row" className="border-b border-slate-100">
                <th scope="row" className={`${CELL} font-medium text-slate-900`}>
                  {r.label}
                </th>
                <td className={`${CELL} tabular-nums text-slate-800`}>{r.yours}</td>
                <td className={`${CELL} tabular-nums text-slate-800`}>{r.lead}</td>
                <td className="py-2">{r.different && <Badge tone="amber">Different</Badge>}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr>
              <th scope="row" className={`${CELL} font-semibold text-slate-900`}>
                Total
              </th>
              <td data-testid="feedback-total" className={`${CELL} font-semibold tabular-nums text-slate-900`}>
                {totalText(f.total, f.maxTotal)}
              </td>
              <td data-testid="feedback-lead-total" className={`${CELL} font-semibold tabular-nums text-slate-900`}>
                {totalText(f.leadTotal, f.maxTotal)}
              </td>
              <td />
            </tr>
          </tfoot>
        </table>
      </div>
      {f.note && (
        <div className="rounded border border-slate-200 bg-slate-50 p-3 text-sm">
          <h3 className="font-medium text-slate-900">The lead marker&apos;s note</h3>
          <p className="mt-1 whitespace-pre-wrap text-slate-700">{f.note}</p>
        </div>
      )}
    </section>
  );
}
