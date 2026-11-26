import { Suspense } from "react";
import { paymentMessageFor } from "@stem/shared";
import { AppShell, Card } from "@/components/AppShell";
import { Statements } from "@/components/marking/Statements";
import { currentMonth, isMonth, lastEndedMonth, parseStatements, pickerMonths } from "@/lib/marker-pay";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

type Params = Record<string, string | string[] | undefined>;

const first = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v) ?? "";

/** The month asked for ("2027-03"), up to the month still running in UK time; else the last month that has ended. */
async function Body({ searchParams }: { searchParams: Promise<Params> }) {
  await requireStaff(["admin", "owner"]);
  const sp = await searchParams;
  const now = new Date().toISOString();
  const asked = first(sp.month);
  const month = isMonth(asked) && asked <= currentMonth(now) ? asked : lastEndedMonth(now);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("marker_statements_get", { p_month: `${month}-01` });
  const r = error ? null : parseStatements(data);
  if (!r) {
    return (
      <Card>
        <p role="alert" className="text-sm text-red-700">
          The statements could not be loaded. Refresh the page to try again.
        </p>
      </Card>
    );
  }
  if (!r.ok) {
    return (
      <Card>
        <p className="text-sm text-slate-700">{paymentMessageFor(r.code)}</p>
      </Card>
    );
  }
  return <Statements key={month} statements={r.statements} picker={pickerMonths(now, month)} />;
}

/** 3B Task 12: marker payments, for admins and the owner: each month's statements, fixing them, and the CSV. Examiner
 * pay only; paying markers happens outside this system. */
export default function MarkerPaymentsPage({ searchParams }: { searchParams: Promise<Params> }) {
  return (
    <AppShell role="admin" title="Marker payments">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading the statements...</p>}>
        <Body searchParams={searchParams} />
      </Suspense>
    </AppShell>
  );
}
