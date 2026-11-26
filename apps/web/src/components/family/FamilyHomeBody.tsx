import Link from "next/link";
import { Badge, Card } from "@/components/AppShell";
import { STATUS_LABEL, STATUS_TONE } from "@/components/bookings/status";
import { SITTING_MODE_LABEL } from "@/lib/exam-form";
import { familyHome, type FamilyBookingRow, type HomeExam } from "@/lib/family-home";
import { formatLondon } from "@/lib/money";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

type Row = Omit<FamilyBookingRow, "exam"> & { exam: FamilyBookingRow["exam"] | NonNullable<FamilyBookingRow["exam"]>[] };

function ExamList({ exams, empty, testId }: { exams: HomeExam[]; empty: string; testId: string }) {
  if (exams.length === 0) return <p className="text-sm text-slate-500">{empty}</p>;
  return (
    <ul className="divide-y divide-slate-100">
      {exams.map((e) => (
        <li key={e.bookingId} data-testid={testId} className="flex flex-wrap items-center justify-between gap-2 py-3 text-sm">
          <span>
            <span className="font-medium text-slate-900">{e.examTitle}</span>
            {e.childName && <span className="ml-2 text-slate-600">For {e.childName}</span>}
            <span className="block text-slate-500">
              {formatLondon(e.startsAt)} · {SITTING_MODE_LABEL[e.sitting]}
            </span>
          </span>
          <Badge tone={STATUS_TONE[e.status]}>{STATUS_LABEL[e.status]}</Badge>
        </li>
      ))}
    </ul>
  );
}

/** The home of a signed-in student or parent: their next exams, past exams, and the way to book. */
export async function FamilyHomeBody({ role }: { role: "student" | "parent" }) {
  await requireStaff([role]);
  const supabase = await createClient();
  // Row level security limits this to the student's own bookings, or a parent's linked children.
  const { data, error } = await supabase
    .from("bookings")
    .select("id, status, student_id, sitting, exam:exams(title, starts_at)")
    .order("created_at", { ascending: false });
  const rows = ((data ?? []) as unknown as Row[]).map((r) => ({ ...r, exam: Array.isArray(r.exam) ? (r.exam[0] ?? null) : r.exam }));

  let firstNames: Map<string, string> | undefined;
  if (role === "parent") {
    firstNames = new Map();
    const ids = [...new Set(rows.map((r) => r.student_id).filter(Boolean))];
    if (ids.length) {
      const { data: ps } = await supabase.from("profiles").select("id, first_name").in("id", ids);
      for (const p of ps ?? []) firstNames.set(p.id, p.first_name);
    }
  }

  const { upcoming, past } = familyHome(rows, new Date(), firstNames);
  return (
    <div className="space-y-6">
      {error && (
        <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">Your exams could not be loaded. Please try again.</p>
      )}
      {!error && upcoming.length === 0 && past.length === 0 && (
        <p className="rounded-lg border border-slate-200 bg-white p-4 text-sm text-slate-600">No exams booked yet.</p>
      )}
      <Card title="Your next exams">
        <ExamList exams={upcoming} empty="No exams coming up." testId="home-upcoming" />
      </Card>
      <Card title="Past exams">
        <ExamList exams={past} empty="No past exams yet." testId="home-past" />
      </Card>
      <Card title="Book an exam">
        <p className="mb-3 text-sm text-slate-600">See the timetable and choose an exam.</p>
        <Link href="/exams" className="text-sm font-medium text-blue-700 underline">Book an exam</Link>
      </Card>
    </div>
  );
}
