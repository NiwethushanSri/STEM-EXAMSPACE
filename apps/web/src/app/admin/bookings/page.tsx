import Link from "next/link";
import { Suspense } from "react";
import { AppShell, Card } from "@/components/AppShell";
import { AdminBookingsManager } from "@/components/bookings/AdminBookingsManager";
import { STATUS_LABEL, type BookingStatus } from "@/components/bookings/status";
import { BOOKING_CAP, loadAdminBookings } from "@/lib/bookings-admin";
import { formatLondon } from "@/lib/money";

type Params = { status?: string | string[]; exam?: string | string[]; q?: string | string[] };
const first = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v) ?? "";

async function Body({ searchParams }: { searchParams: Promise<Params> }) {
  const p = await searchParams;
  const status = first(p.status);
  const exam = first(p.exam);
  const q = first(p.q).slice(0, 200);
  const { rows, capped, decidable, exams } = await loadAdminBookings({ status, exam, q });
  const filtered = Boolean(status || exam || q);

  return (
    <div className="space-y-5">
      <Card title="Filter bookings">
        <form method="get" action="/admin/bookings" aria-label="Filter bookings" className="flex flex-wrap items-end gap-3 text-sm">
          <label className="flex flex-col gap-1">
            Status
            <select name="status" defaultValue={status} className="rounded border border-slate-300 bg-white px-2 py-1.5">
              <option value="">All</option>
              {(Object.keys(STATUS_LABEL) as BookingStatus[]).map((s) => (
                <option key={s} value={s}>{STATUS_LABEL[s]}</option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1">
            Exam
            <select name="exam" defaultValue={exam} className="max-w-72 rounded border border-slate-300 bg-white px-2 py-1.5">
              <option value="">All exams</option>
              {exams.map((e) => (
                <option key={e.id} value={e.id}>{e.label} — {formatLondon(e.startsAt)}</option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1">
            Student name or index number
            <input name="q" type="search" defaultValue={q} maxLength={200} className="w-64 rounded border border-slate-300 px-2 py-1.5" />
          </label>
          <button type="submit" className="rounded bg-blue-600 px-4 py-1.5 font-medium text-white hover:bg-blue-700">Apply filters</button>
          {filtered && (
            <Link href="/admin/bookings" className="py-1.5 text-blue-700 underline">Clear filters</Link>
          )}
        </form>
      </Card>
      <AdminBookingsManager rows={rows} decidable={decidable} exams={exams} capped={capped} cap={BOOKING_CAP} />
    </div>
  );
}

export default function AdminBookings({ searchParams }: { searchParams: Promise<Params> }) {
  return (
    <AppShell role="admin" title="Bookings & payments">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading bookings...</p>}>
        <Body searchParams={searchParams} />
      </Suspense>
    </AppShell>
  );
}
