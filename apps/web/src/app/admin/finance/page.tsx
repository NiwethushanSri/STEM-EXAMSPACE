import Link from "next/link";
import { Suspense } from "react";
import { adminBookingMessageFor } from "@stem/shared";
import { AppShell, Card, Stat } from "@/components/AppShell";
import { readMoneyTotals, monthLabel, resolveRange } from "@/lib/finance";
import { formatLondon, formatMoney } from "@/lib/money";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

type Params = { from?: string | string[]; to?: string | string[] };

async function Body({ searchParams }: { searchParams: Promise<Params> }) {
  await requireStaff(["admin", "owner"]);
  const p = await searchParams;
  const range = resolveRange(p.from, p.to, new Date());
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("money_totals", { p_from: range.from, p_to: range.to });
  const res = data && typeof data === "object" && !Array.isArray(data) ? (data as { ok?: unknown; code?: unknown }) : null;
  const totals = !error && res?.ok === true ? readMoneyTotals(data) : null;

  return (
    <div className="space-y-5">
      <Card title="Date range">
        <form method="get" action="/admin/finance" aria-label="Date range" className="flex flex-wrap items-end gap-3 text-sm">
          <label className="flex flex-col gap-1">
            From
            <input name="from" type="date" required defaultValue={range.from} className="rounded border border-slate-300 px-2 py-1.5" />
          </label>
          <label className="flex flex-col gap-1">
            To
            <input name="to" type="date" required defaultValue={range.to} className="rounded border border-slate-300 px-2 py-1.5" />
          </label>
          <button type="submit" className="rounded bg-blue-600 px-4 py-1.5 font-medium text-white hover:bg-blue-700">Show totals</button>
          {!range.usedDefault && <Link href="/admin/finance" className="py-1.5 text-blue-700 underline">This financial year</Link>}
        </form>
        <p className="mt-3 text-xs text-slate-500">
          {range.usedDefault ? "Showing the current financial year (1 September to 31 August). " : ""}
          Dates are UK dates and both ends are included. Money is counted on the day a booking was paid.
          Refunds are shown against the month the booking was paid.
        </p>
        {range.invalid && (
          <p role="alert" className="mt-2 text-sm text-red-700">{adminBookingMessageFor("invalid_input", "finance")} Showing the current financial year instead.</p>
        )}
      </Card>

      {!totals ? (
        <p role="alert" className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-800">
          {adminBookingMessageFor(typeof res?.code === "string" ? res.code : undefined, "finance")}
        </p>
      ) : (
        <>
          <div className="grid gap-4 sm:grid-cols-3" data-testid="finance-total">
            <Stat label="Money taken" value={formatMoney(totals.total.taken)} />
            <Stat label="Refunded" value={formatMoney(totals.total.refunded)} />
            <Stat label="Net" value={formatMoney(totals.total.net)} />
          </div>

          <Card title="By month">
            {totals.months.length === 0 ? (
              <p className="text-sm text-slate-500">No bookings were paid in this period.</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm">
                  <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                    <tr>
                      <th className="py-2 pr-4 font-medium">Month paid</th>
                      <th className="py-2 pr-4 text-right font-medium">Bookings</th>
                      <th className="py-2 pr-4 text-right font-medium">Taken</th>
                      <th className="py-2 pr-4 text-right font-medium">Refunded</th>
                      <th className="py-2 text-right font-medium">Net</th>
                    </tr>
                  </thead>
                  <tbody>
                    {totals.months.map((m) => (
                      <tr key={m.month} data-testid="month-row" className="border-b border-slate-100 last:border-0">
                        <td className="py-2.5 pr-4">{monthLabel(m.month)}</td>
                        <td className="py-2.5 pr-4 text-right">{m.bookings}</td>
                        <td className="py-2.5 pr-4 text-right">{formatMoney(m.taken)}</td>
                        <td className="py-2.5 pr-4 text-right">{formatMoney(m.refunded)}</td>
                        <td className="py-2.5 text-right font-medium">{formatMoney(m.net)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          <Card title="By exam">
            {totals.exams.length === 0 ? (
              <p className="text-sm text-slate-500">No bookings were paid in this period.</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm">
                  <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                    <tr>
                      <th className="py-2 pr-4 font-medium">Exam</th>
                      <th className="py-2 pr-4 font-medium">Date</th>
                      <th className="py-2 pr-4 text-right font-medium">Bookings</th>
                      <th className="py-2 pr-4 text-right font-medium">Taken</th>
                      <th className="py-2 pr-4 text-right font-medium">Refunded</th>
                      <th className="py-2 text-right font-medium">Net</th>
                    </tr>
                  </thead>
                  <tbody>
                    {totals.exams.map((e) => (
                      <tr key={e.examId} data-testid="exam-money-row" className="border-b border-slate-100 last:border-0">
                        <td className="py-2.5 pr-4">
                          <div>{e.title}</div>
                          <div className="text-xs text-slate-500">{e.subject}</div>
                        </td>
                        <td className="py-2.5 pr-4">{formatLondon(e.startsAt)}</td>
                        <td className="py-2.5 pr-4 text-right">{e.bookings}</td>
                        <td className="py-2.5 pr-4 text-right">{formatMoney(e.taken)}</td>
                        <td className="py-2.5 pr-4 text-right">{formatMoney(e.refunded)}</td>
                        <td className="py-2.5 text-right font-medium">{formatMoney(e.net)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>
        </>
      )}
    </div>
  );
}

export default function AdminFinance({ searchParams }: { searchParams: Promise<Params> }) {
  return (
    <AppShell role="admin" title="Finance">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading finance...</p>}>
        <Body searchParams={searchParams} />
      </Suspense>
    </AppShell>
  );
}
