import Link from "next/link";
import { Suspense } from "react";
import { redirect } from "next/navigation";
import { homeFor } from "@stem/shared";
import { CancelButton } from "@/components/bookings/CancelButton";
import { Frame } from "@/components/bookings/Frame";
import { STATUS_LABEL, STATUS_TONE, type BookingStatus } from "@/components/bookings/status";
import { Badge } from "@/components/AppShell";
import { formatLondon, formatPence } from "@/lib/money";
import { createClient, getSessionProfile } from "@/lib/supabase/server";

type Row = {
  id: string;
  status: BookingStatus;
  amount_pence: number;
  student_id: string;
  created_at: string;
  exam:
    | {
        id: string;
        status: string;
        starts_at: string;
        duration_minutes: number;
        format: "in_person" | "online";
        subject: { name: string } | { name: string }[] | null;
        venue: { name: string } | { name: string }[] | null;
      }
    | null;
};

const one = <T,>(v: T | T[] | null | undefined): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));
const LIVE: BookingStatus[] = ["awaiting_payment", "paid", "cancel_requested"];

async function Content({ searchParams }: { searchParams: Promise<{ booked?: string }> }) {
  const me = await getSessionProfile();
  if (!me || me.status === "unconfirmed") redirect("/login");
  if (me.status !== "active" || (me.role !== "student" && me.role !== "parent")) redirect(homeFor(me.role, me.status, "web-staff"));
  const booked = (await searchParams).booked === "1";

  const supabase = await createClient();
  // Row level security limits this to the student's own bookings, or a parent's linked children.
  const { data, error } = await supabase
    .from("bookings")
    .select(
      "id, status, amount_pence, student_id, created_at, exam:exams(id, status, starts_at, duration_minutes, format, subject:subjects(name), venue:venues(name))",
    )
    .order("created_at", { ascending: false });
  const rows = (data ?? []) as unknown as Row[];

  const names = new Map<string, string>();
  if (me.role === "parent" && rows.length) {
    const ids = [...new Set(rows.map((r) => r.student_id).filter(Boolean))];
    const { data: ps } = await supabase.from("profiles").select("id, first_name, last_name").in("id", ids);
    for (const p of ps ?? []) names.set(p.id, `${p.first_name} ${p.last_name}`.trim());
  }

  const now = new Date();
  const startsAt = (r: Row) => (r.exam ? new Date(r.exam.starts_at) : null);
  const upcoming = rows
    .filter((r) => LIVE.includes(r.status) && (startsAt(r)?.getTime() ?? 0) > now.getTime())
    .sort((a, b) => startsAt(a)!.getTime() - startsAt(b)!.getTime());
  const past = rows.filter((r) => !upcoming.includes(r));

  const renderRow = (r: Row) => {
    const subject = one(r.exam?.subject)?.name ?? "Exam";
    const examCancelled = r.exam?.status === "cancelled";
    const venue = one(r.exam?.venue)?.name;
    const future = !!r.exam && new Date(r.exam.starts_at) > now && r.exam.status !== "cancelled";
    return (
      <li key={r.id} data-testid="booking-row" className="space-y-2 p-4 text-sm">
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div>
            <div className="text-base font-semibold text-blue-800">{subject}</div>
            {me.role === "parent" && <div className="text-slate-600">For {names.get(r.student_id) ?? "your child"}</div>}
          </div>
          <Badge tone={STATUS_TONE[r.status]}>{STATUS_LABEL[r.status]}</Badge>
        </div>
        {r.exam ? (
          <div className="text-slate-600">
            {examCancelled && <span className="mr-2 font-medium text-red-700">Exam cancelled</span>}
            {formatLondon(r.exam.starts_at)} · {r.exam.duration_minutes} min · {r.exam.format === "online" ? "Online" : (venue ?? "Venue to be confirmed")}
          </div>
        ) : (
          <div className="text-slate-600">This exam is no longer on the timetable.</div>
        )}
        <div className="text-slate-600">{formatPence(r.amount_pence)}</div>
        {future && r.status === "awaiting_payment" && <CancelButton bookingId={r.id} paid={false} />}
        {future && r.status === "paid" && <CancelButton bookingId={r.id} paid />}
      </li>
    );
  };

  return (
    <Frame signedIn>
      <Link href="/account/home" className="text-sm text-blue-700 hover:underline">Back to my account</Link>
      <h1 className="mt-3 text-2xl font-semibold">My bookings</h1>
      {booked && (
        <p role="status" className="mt-4 rounded-lg bg-green-50 px-3 py-2 text-sm text-green-800">Booking saved.</p>
      )}
      {error && (
        <p role="alert" className="mt-4 rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">Your bookings could not be loaded. Please try again.</p>
      )}
      <h2 className="mb-2 mt-6 font-semibold">Upcoming</h2>
      {upcoming.length === 0 ? (
        <p className="rounded-lg border border-slate-200 bg-white p-4 text-sm text-slate-500">
          No upcoming bookings. <Link href="/exams" className="text-blue-700 underline">See the timetable</Link>.
        </p>
      ) : (
        <ul className="divide-y divide-slate-200 rounded-lg border border-slate-200 bg-white">{upcoming.map(renderRow)}</ul>
      )}
      <h2 className="mb-2 mt-8 font-semibold">Past</h2>
      {past.length === 0 ? (
        <p className="rounded-lg border border-slate-200 bg-white p-4 text-sm text-slate-500">Nothing here yet.</p>
      ) : (
        <ul className="divide-y divide-slate-200 rounded-lg border border-slate-200 bg-white">{past.map(renderRow)}</ul>
      )}
    </Frame>
  );
}

export default function BookingsPage({ searchParams }: { searchParams: Promise<{ booked?: string }> }) {
  return (
    <Suspense fallback={null}>
      <Content searchParams={searchParams} />
    </Suspense>
  );
}
