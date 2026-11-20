"use client";

import { pageList, UPLOAD_TEXT } from "@/lib/home-upload";
import { formatLondon } from "@/lib/money";

const QUIET = "rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-sm font-semibold text-slate-800 hover:bg-slate-50";

/**
 * The receipt a family keeps once the server has received their answers: the exam, the script number, the
 * submission, when it was handed in, the page count and the pages, with Print. Shown only for a submission the
 * server says is received.
 */
export function UploadReceipt({
  label,
  scriptNumber,
  seq,
  submittedAt,
  pages,
  blank,
  late,
}: {
  label: string;
  scriptNumber: string | null;
  seq: number;
  submittedAt: string | null;
  pages: number[];
  blank: number[];
  late: boolean;
}) {
  return (
    <section aria-labelledby={`receipt-${seq}`} data-testid="upload-receipt"
      className="space-y-2 rounded-lg border border-green-200 bg-green-50 p-3 text-slate-800 print:border-slate-400 print:bg-white">
      <h3 id={`receipt-${seq}`} className="font-semibold text-green-900">{UPLOAD_TEXT.receiptHeading}</h3>
      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5">
        <dt className="text-slate-600">Exam</dt>
        <dd>{label}</dd>
        {scriptNumber && (
          <>
            <dt className="text-slate-600">Script number</dt>
            <dd data-testid="receipt-script" className="font-semibold tabular-nums">{scriptNumber}</dd>
          </>
        )}
        <dt className="text-slate-600">Submission</dt>
        <dd className="tabular-nums">{seq}</dd>
        {submittedAt && (
          <>
            <dt className="text-slate-600">Handed in</dt>
            <dd>{formatLondon(submittedAt)}</dd>
          </>
        )}
        <dt className="text-slate-600">Pages</dt>
        <dd data-testid="receipt-count" className="tabular-nums">{pages.length}</dd>
      </dl>
      {pages.length > 0 && (
        <p data-testid="receipt-pages">
          {pages.length === 1 ? "Page received: " : "Pages received: "}
          {pageList(pages)}
        </p>
      )}
      {blank.length > 0 && <p>Left blank: {pageList(blank)}</p>}
      {late && <p className="text-amber-900">{UPLOAD_TEXT.late}. {UPLOAD_TEXT.lateNote}</p>}
      <button type="button" className={`${QUIET} print:hidden`} onClick={() => window.print()}>
        {UPLOAD_TEXT.print}<span className="sr-only"> the receipt for {label}</span>
      </button>
    </section>
  );
}
