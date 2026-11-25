"use client";

import { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Badge, Card } from "@/components/AppShell";
import { ConfirmDialog } from "@/components/accounts/ConfirmDialog";
import { exportCsv, fixMonth, type CsvResult, type PayActionResult } from "@/app/admin/marking/payments/actions";
import {
  examName,
  fixedText,
  groupText,
  kindLabel,
  markerName,
  monthLabel,
  penceToPounds,
  type MarkerStatement,
  type RateMissingExam,
  type Statements as MonthStatements,
} from "@/lib/marker-pay";

const GENERIC = "Something went wrong. Please try again.";
const FIELD = "rounded border border-slate-300 px-3 py-2 text-sm";
const PRIMARY = "rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50";
const QUIET = "rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";

function saveBlob(blob: Blob, fileName: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

/** The exams with no pay rate, each linked to its page (where Marker pay sets it). */
function MissingRates({ exams }: { exams: RateMissingExam[] }) {
  return (
    <ul className="mt-1 list-inside list-disc">
      {exams.map((e) => (
        <li key={e.examId}>
          <Link href={`/admin/exams/${e.examId}`} className="text-blue-700 underline">
            {examName(e.title, e.paper)}
          </Link>
        </li>
      ))}
    </ul>
  );
}

/** 3B Task 12: a month's marker statements for admins. Per marker, the lines (exam, paper, question group, kind,
 * scripts, rate, amount) and the total, and whether the statement is fixed; Fix (once the month has ended) and the CSV.
 * An amount that is not known (no rate yet) is never shown as a figure. */
export function Statements({ statements: s, picker }: { statements: MonthStatements; picker: { ended: string[]; current: string } }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [refusal, setRefusal] = useState<Extract<PayActionResult, { ok: false }> | null>(null);

  const label = monthLabel(s.month);
  const toFix = s.markers.some((m) => m.fixedAt === null);

  async function fix() {
    setBusy(true);
    const res = await fixMonth(s.month).catch((): PayActionResult => ({ ok: false, message: GENERIC }));
    setBusy(false);
    setConfirming(false);
    if (res.ok) {
      setRefusal(null);
      setNotice(res.message);
      router.refresh();
    } else {
      setNotice(null);
      setRefusal(res);
    }
  }

  async function download() {
    setBusy(true);
    setNotice(null);
    setRefusal(null);
    const res = await exportCsv(s.month).catch((): CsvResult => ({ ok: false, message: GENERIC }));
    setBusy(false);
    if (res.ok) saveBlob(new Blob([res.csv], { type: "text/csv;charset=utf-8" }), res.filename);
    else setRefusal({ ok: false, message: res.message });
  }

  return (
    <div className="space-y-5">
      <form method="get" action="/admin/marking/payments" aria-label="Choose a month" className="flex flex-wrap items-end gap-3 text-sm">
        <label className="flex flex-col gap-1">
          Month
          <select name="month" defaultValue={s.month} className={FIELD}>
            <optgroup label="Ended">
              {picker.ended.map((m) => (
                <option key={m} value={m}>
                  {monthLabel(m)}
                </option>
              ))}
            </optgroup>
            <optgroup label="Not ended yet">
              <option value={picker.current}>{monthLabel(picker.current)}</option>
            </optgroup>
          </select>
        </label>
        <button type="submit" className={QUIET}>
          Show
        </button>
      </form>

      <Card title={`Statements: ${label}`}>
        <div aria-live="polite">
          {notice && (
            <div role="status" className="mb-3 rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">
              {notice}
            </div>
          )}
          {refusal && (
            <div role="alert" className="mb-3 rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">
              <p>{refusal.message}</p>
              {refusal.month && (
                <Link href={`/admin/marking/payments?month=${refusal.month}`} className="mt-1 inline-block text-blue-700 underline">
                  Show {monthLabel(refusal.month)}
                </Link>
              )}
              {refusal.exams && refusal.exams.length > 0 && <MissingRates exams={refusal.exams} />}
            </div>
          )}
        </div>

        {s.rateMissing.length > 0 && (
          <div data-testid="rate-missing" className="mb-3 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
            <p>These exams have no pay rate yet. Set it under Marker pay on the exam&apos;s page.</p>
            <MissingRates exams={s.rateMissing} />
          </div>
        )}

        <div className="flex flex-wrap items-center gap-2">
          <button type="button" disabled={busy || !s.ended || !toFix} onClick={() => setConfirming(true)} className={PRIMARY}>
            Fix this month&apos;s statements
          </button>
          <button type="button" disabled={busy || s.markers.length === 0} onClick={() => void download()} className={QUIET}>
            Download CSV
          </button>
        </div>
        <p className="mt-2 text-xs text-slate-500">
          {!s.ended
            ? "This month has not ended yet."
            : s.markers.length > 0 && !toFix
              ? "Every statement for this month is fixed."
              : "Fixed statements never change. Marking submitted after a fix is paid in a later month."}
        </p>

        {s.markers.length === 0 ? (
          <p className="mt-4 text-sm text-slate-700">There is no marking to pay for {label}.</p>
        ) : (
          <div className="mt-4 space-y-6">
            {s.markers.map((m) => (
              <MarkerLines key={m.markerId} marker={m} />
            ))}
          </div>
        )}
      </Card>

      <p className="text-sm text-slate-500">Practice and seeded scripts are not paid. Paying markers happens outside this system.</p>

      {confirming && (
        <ConfirmDialog
          title={`Fix the statements for ${label}?`}
          confirmLabel="Fix this month's statements"
          tone="primary"
          busy={busy}
          onConfirm={() => void fix()}
          onCancel={() => {
            if (!busy) setConfirming(false);
          }}
        >
          <p className="text-sm text-slate-700">
            Each marker&apos;s statement is fixed with the scripts and pay shown here. Fixed statements never change. Marking submitted later is
            paid in a later month.
          </p>
        </ConfirmDialog>
      )}
    </div>
  );
}

/** One marker's statement: its lines and total, and whether it is fixed. */
function MarkerLines({ marker: m }: { marker: MarkerStatement }) {
  return (
    <section aria-label={markerName(m.name)}>
      <div className="flex flex-wrap items-center gap-2">
        <h3 className="text-sm font-semibold text-slate-900">{markerName(m.name)}</h3>
        {m.fixedAt ? <Badge tone="green">{fixedText(m.fixedAt)}</Badge> : <Badge tone="amber">Not fixed</Badge>}
      </div>
      {!m.fixedAt && <p className="mt-1 text-xs text-slate-500">{fixedText(null)}</p>}
      <div className="mt-2 overflow-x-auto">
        <table className="w-full text-left text-sm">
          <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className="py-2 pr-4 font-medium">Exam</th>
              <th className="py-2 pr-4 font-medium">Paper</th>
              <th className="py-2 pr-4 font-medium">Question group</th>
              <th className="py-2 pr-4 font-medium">Kind</th>
              <th className="py-2 pr-4 text-right font-medium">Scripts</th>
              <th className="py-2 pr-4 text-right font-medium">Rate</th>
              <th className="py-2 pr-4 text-right font-medium">Amount</th>
            </tr>
          </thead>
          <tbody>
            {m.lines.map((l, i) => (
              <tr key={i} className="border-b border-slate-100">
                <td className="py-2 pr-4">{l.examTitle}</td>
                <td className="py-2 pr-4">{l.paper}</td>
                <td className="py-2 pr-4">{groupText(l.groupLabel)}</td>
                <td className="py-2 pr-4">{kindLabel(l.kind)}</td>
                <td className="py-2 pr-4 text-right tabular-nums">{l.pieces}</td>
                <td className="py-2 pr-4 text-right tabular-nums">
                  {l.ratePence === null ? <span className="text-amber-800">Rate not set</span> : penceToPounds(l.ratePence)}
                </td>
                <td className="py-2 pr-4 text-right tabular-nums">{l.pence === null ? "" : penceToPounds(l.pence)}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="font-medium text-slate-900">
              <td className="py-2 pr-4" colSpan={4}>
                Total
              </td>
              <td className="py-2 pr-4 text-right tabular-nums">{m.pieces}</td>
              <td className="py-2 pr-4" />
              <td className="py-2 pr-4 text-right tabular-nums">
                {m.totalPence === null ? <span className="text-xs font-normal text-slate-500">Not known until every rate is set</span> : penceToPounds(m.totalPence)}
              </td>
            </tr>
          </tfoot>
        </table>
      </div>
    </section>
  );
}
