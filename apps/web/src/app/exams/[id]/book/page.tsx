import Link from "next/link";
import { Suspense } from "react";
import { notFound, redirect } from "next/navigation";
import { homeFor } from "@stem/shared";
import { BookForm, type Child } from "@/components/bookings/BookForm";
import { Frame } from "@/components/bookings/Frame";
import { PAY_NOTE } from "@/components/bookings/status";
import { isClosed } from "@/lib/exam-state";
import { formatLondon, formatPence } from "@/lib/money";
import { createClient, getSessionProfile } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";


async function Content({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!isUuid(id)) notFound();

  // Signed-out visitors sign in first and come back here (the return path is a fixed internal path).
  const me = await getSessionProfile();
  if (!me || me.status === "unconfirmed") redirect(`/login?next=${encodeURIComponent(`/exams/${id}/book`)}`);
  if (me.status !== "active" || (me.role !== "student" && me.role !== "parent")) redirect(homeFor(me.role, me.status, "web-staff"));

  const supabase = await createClient();
  const { data: exam } = await supabase
    .from("exams_public")
    .select("id, subject, format, venue, starts_at, duration_minutes, price_pence, booking_deadline, seats_left")
    .eq("id", id)
    .maybeSingle();
  if (!exam || !exam.starts_at || !exam.booking_deadline) notFound();

  let children: Child[] | null = null;
  if (me.role === "parent") {
    const { data: links } = await supabase.from("parent_children").select("student_id").eq("parent_id", me.id);
    const ids = (links ?? []).map((l) => l.student_id);
    const { data: kids } = ids.length
      ? await supabase.from("profiles").select("id, first_name, last_name, status").in("id", ids).eq("status", "active").order("first_name")
      : { data: [] };
    children = (kids ?? []).map((k) => ({ id: k.id, name: `${k.first_name} ${k.last_name}`.trim() }));
  }

  const now = new Date();
  const closed = isClosed({ booking_deadline: exam.booking_deadline, starts_at: exam.starts_at }, now);
  const full = (exam.seats_left ?? 0) <= 0;
  const price = exam.price_pence ?? 0;

  return (
    <Frame signedIn>
      <Link href="/exams" className="text-sm text-blue-700 hover:underline">Back to the timetable</Link>
      <h1 className="mt-3 text-2xl font-semibold">Book {exam.subject}</h1>
      <dl className="mt-4 grid gap-2 rounded-lg border border-slate-200 bg-white p-4 text-sm sm:grid-cols-2">
        <div><dt className="text-slate-500">When</dt><dd className="font-medium">{formatLondon(exam.starts_at)} ({exam.duration_minutes} min)</dd></div>
        <div><dt className="text-slate-500">Where</dt><dd className="font-medium">{exam.format === "online" ? "Online" : (exam.venue ?? "Venue to be confirmed")}</dd></div>
        <div><dt className="text-slate-500">Price</dt><dd className="font-medium">{formatPence(price)}</dd></div>
        <div><dt className="text-slate-500">Book by</dt><dd className="font-medium">{formatLondon(exam.booking_deadline)}</dd></div>
      </dl>
      {price > 0 && <p className="mt-4 rounded-lg bg-blue-50 px-4 py-3 text-sm text-blue-900">{PAY_NOTE}</p>}

      {closed ? (
        <p role="alert" className="mt-6 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">The booking deadline for this exam has passed.</p>
      ) : full ? (
        <p role="alert" className="mt-6 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">This exam is fully booked</p>
      ) : children && children.length === 0 ? (
        <p role="alert" className="mt-6 rounded-lg bg-amber-50 px-3 py-2 text-sm text-amber-900">
          No active linked student found. A student must be approved and linked to your account before you can book.
        </p>
      ) : (
        <BookForm examId={id} kids={children} />
      )}
    </Frame>
  );
}

export default function BookPage({ params }: { params: Promise<{ id: string }> }) {
  return (
    <Suspense fallback={null}>
      <Content params={params} />
    </Suspense>
  );
}
