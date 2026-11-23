"use client";

import { useEffectEvent, useLayoutEffect } from "react";
import type { MarkEntry } from "@/lib/marking-marks";
import { PAGE_ASPECT } from "@/lib/page-view";
import { formatMark, questionMarkText, type ScreenPage, type ScreenQuestion } from "@/lib/marking-screen";
import { FOCUS } from "@/components/marking/ToolBar";

/**
 * The left area: every question of the piece with its mark so far ("NR", or a dash for none yet), the running total,
 * then the page thumbnails, the pages of the current question outlined. Choosing a question makes it current (the
 * screen shows its first page); choosing a thumbnail shows that page. `urls` holds the signed links the screen asked
 * for; a page without one shows its number only. A thumbnail asks for its link (onThumb) when it appears, so an old one
 * is never shown; under a cover the screen passes no links and asks for none.
 */
export function QuestionList({
  questions,
  marks,
  currentId,
  onQuestion,
  total,
  max,
  pages,
  pageIndex,
  questionPages,
  onPage,
  urls,
  onThumb,
}: {
  questions: ScreenQuestion[];
  marks: Record<string, MarkEntry>;
  currentId: string | null;
  onQuestion: (q: ScreenQuestion) => void;
  total: number;
  max: number;
  pages: ScreenPage[];
  pageIndex: number;
  questionPages: number[];
  onPage: (index: number) => void;
  urls: Record<string, string>;
  /** The thumbnail of this page's picture appeared: the screen asks for its link unless a recent one is still good. */
  onThumb: (pageId: string) => void;
}) {
  const current = questions.find((q) => q.id === currentId);
  const outlined = new Set(questionPages);
  return (
    <nav aria-label="Questions and pages" className="flex h-full flex-col gap-4 overflow-y-auto p-3">
      <section aria-label="Questions">
        <h2 className="mb-2 text-sm font-semibold text-slate-900">Questions</h2>
        <ul className="space-y-1">
          {questions.map((q) => {
            const mark = questionMarkText(q, questions, marks);
            const isCurrent = q.id === currentId || (!!current && !q.leaf && isAncestor(q, current, questions));
            return (
              <li key={q.id}>
                <button
                  type="button"
                  data-testid={`question-${q.label}`}
                  aria-current={q.id === currentId ? "true" : undefined}
                  aria-label={`Question ${q.label}: ${mark === "–" ? "no mark yet" : mark === "NR" ? "NR, no response" : `${mark}${q.leaf && q.maxMark !== null ? ` of ${formatMark(q.maxMark)}` : ""}`}`}
                  onClick={() => onQuestion(q)}
                  className={`flex min-h-11 w-full items-center justify-between gap-2 rounded px-2 text-left text-sm ${FOCUS} ${
                    q.id === currentId ? "bg-blue-600 text-white" : isCurrent ? "bg-blue-50 text-slate-900" : "text-slate-800 hover:bg-slate-100"
                  }`}
                  style={{ paddingLeft: `${0.5 + q.depth * 1}rem` }}
                >
                  <span className="font-medium">{q.label}</span>
                  <span data-testid={`question-${q.label}-mark`} className="tabular-nums">
                    {mark}
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
        <p className="mt-3 flex items-baseline justify-between border-t border-slate-200 pt-2 text-sm text-slate-900">
          <span className="font-semibold">Total</span>
          <span data-testid="running-total" className="font-semibold tabular-nums">
            {formatMark(total)} / {formatMark(max)}
          </span>
        </p>
      </section>
      <section aria-label="Pages">
        <h2 className="mb-2 text-sm font-semibold text-slate-900">Pages</h2>
        <ul className="grid grid-cols-2 gap-2">
          {pages.map((p, i) => {
            const url = p.hasPicture ? urls[p.pageId] : undefined;
            return (
              <li key={p.pageId}>
                <button
                  type="button"
                  aria-current={i === pageIndex ? "page" : undefined}
                  aria-label={`Page ${i + 1}${p.extra ? ", an extra page" : ""}${outlined.has(i) ? ", this question" : ""}`}
                  onClick={() => onPage(i)}
                  className={`block w-full rounded border bg-white p-1 text-left ${FOCUS} ${
                    outlined.has(i) ? "border-blue-600 ring-2 ring-blue-600" : "border-slate-300"
                  } ${i === pageIndex ? "bg-blue-50" : ""}`}
                >
                  <Thumb pageId={p.hasPicture ? p.pageId : null} url={url} onThumb={onThumb} />
                  <span className="mt-1 block text-center text-sm text-slate-700">
                    {i + 1}
                    {p.extra ? " (extra)" : ""}
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      </section>
    </nav>
  );
}

/** A page's small picture; it asks for its link before it is first drawn. */
function Thumb({ pageId, url, onThumb }: { pageId: string | null; url: string | undefined; onThumb: (pageId: string) => void }) {
  const ask = useEffectEvent((p: string) => onThumb(p));
  // Before paint, so a link that has run out is dropped before its picture could show broken.
  useLayoutEffect(() => {
    if (pageId) ask(pageId);
  }, [pageId]);
  return (
    <span className="block overflow-hidden bg-slate-100" style={{ aspectRatio: `${PAGE_ASPECT}` }}>
      {url && (
        // eslint-disable-next-line @next/next/no-img-element -- a 120-second signed link to a private picture, not optimisable
        <img src={url} alt="" draggable={false} className="block h-full w-full object-contain" />
      )}
    </span>
  );
}

function isAncestor(a: ScreenQuestion, b: ScreenQuestion, questions: ScreenQuestion[]): boolean {
  let cur: ScreenQuestion | undefined = b;
  while (cur && cur.parentId) {
    if (cur.parentId === a.id) return true;
    cur = questions.find((q) => q.id === cur!.parentId);
  }
  return false;
}
