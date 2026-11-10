import Link from "next/link";
import { Suspense } from "react";
import { Frame } from "@/components/bookings/Frame";
import { isClosed } from "@/lib/exam-state";
import { formatLondon, formatPence } from "@/lib/money";
import { createClient, getSessionProfile } from "@/lib/supabase/server";

type Row = {
  id: string;
  subject: string;
  format: "in_person" | "online";
  venue: string | null;
  starts_at: string;
  duration_minutes: number;
  price_pence: number;
  booking_deadline: string;
  seats_left: number;
};

const COLUMNS = "id, subject, format, venue, starts_at, duration_minutes, price_pence, booking_deadline, seats_left";

async function Timetable({ searchParams }: { searchParams: Promise<{ subject?: string | string[] }> }) {
  const supabase = await createClient();
  const me = await getSessionProfile();
  const raw = (await searchParams).subject;
  const wanted = Array.isArray(raw) ? raw[0] : raw;
  const now = new Date();

  // Only the public columns are selected: the view is readable by anyone, so nothing personal is involved.
  const { data, error } = await supabase
    .from("exams_public")
    .select(COLUMNS)
    .gt("starts_at", now.toISOString())
    .order("starts_at", { ascending: true })
    .limit(200);

  const all = ((data ?? []) as unknown as Row[]).filter((r) => r.id);
  const subjects = [...new Set(all.map((r) => r.subject))].sort();
  const subject = wanted && subjects.includes(wanted) ? wanted : null;
  const rows = subject ? all.filter((r) => r.subject === subject) : all;

  return (
    <Frame signedIn={!!me}>
      <h1 className="text-2xl font-semibold">Exam timetable</h1>
      <p className="mt-1 text-sm text-slate-600">Online and face-to-face mock exams. All times are UK time.</p>

      <nav aria-label="Subject filter" className="mt-6 flex flex-wrap gap-2 text-sm">
        <Link
          href="/exams"
          aria-current={subject ? undefined : "true"}
          className={`rounded-full border px-3 py-1 ${subject ? "border-slate-300 bg-white hover:bg-slate-100" : "border-blue-700 bg-blue-700 text-white"}`}
        >
          All subjects
        </Link>
        {subjects.map((s) => (
          <Link
            key={s}
            href={`/exams?subject=${encodeURIComponent(s)}`}
            aria-current={s === subject ? "true" : undefined}
            className={`rounded-full border px-3 py-1 ${s === subject ? "border-blue-700 bg-blue-700 text-white" : "border-slate-300 bg-white hover:bg-slate-100"}`}
          >
            {s}
          </Link>
        ))}
      </nav>

      {error ? (
        <p role="alert" className="mt-6 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">
          The timetable could not be loaded. Please try again.
        </p>
      ) : rows.length === 0 ? (
        <p className="mt-6 rounded-lg border border-slate-200 bg-white p-6 text-center text-sm text-slate-500">
          No upcoming exams{subject ? ` for ${subject}` : ""}.
        </p>
      ) : (
        <ul className="mt-6 divide-y divide-slate-200 rounded-lg border border-slate-200 bg-white">
          {rows.map((e) => {
            const closed = isClosed(e, now);
            const full = e.seats_left <= 0;
            return (
              <li key={e.id} data-testid="exam-row" className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
                <div className="space-y-1 text-sm">
                  <div className="text-base font-semibold text-blue-800">{e.subject}</div>
                  <div>{formatLondon(e.starts_at)} · {e.duration_minutes} min</div>
                  <div className="text-slate-600">{e.format === "online" ? "Online" : (e.venue ?? "Venue to be confirmed")}</div>
                  <div className="text-slate-600">Book by {formatLondon(e.booking_deadline)}</div>
                </div>
                <div className="flex items-center gap-4 text-sm sm:text-right">
                  <div>
                    <div className="font-semibold">{formatPence(e.price_pence)}</div>
                    <div className="text-slate-500">{full ? "No seats left" : `${e.seats_left} seat${e.seats_left === 1 ? "" : "s"} left`}</div>
                  </div>
                  {closed ? (
                    <button type="button" disabled className="rounded-lg bg-slate-200 px-4 py-2 font-medium text-slate-500">Booking closed</button>
                  ) : full ? (
                    <button type="button" disabled className="rounded-lg bg-slate-200 px-4 py-2 font-medium text-slate-500">Fully booked</button>
                  ) : (
                    <Link href={`/exams/${e.id}/book`} className="rounded-lg bg-blue-600 px-4 py-2 font-semibold text-white hover:bg-blue-700">Book</Link>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </Frame>
  );
}

export default function ExamsPage({ searchParams }: { searchParams: Promise<{ subject?: string | string[] }> }) {
  return (
    <Suspense fallback={null}>
      <Timetable searchParams={searchParams} />
    </Suspense>
  );
}
