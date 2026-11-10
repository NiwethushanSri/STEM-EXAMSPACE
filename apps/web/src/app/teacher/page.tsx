import Link from "next/link";
import { Suspense } from "react";
import { AppShell, Card, Stat } from "@/components/AppShell";
import { formatLondon } from "@/lib/money";
import { loadTeacherHome } from "@/lib/staff-homes";

async function Body() {
  const { upcoming, drafts } = await loadTeacherHome();
  return (
    <div className="space-y-6">
      <div className="grid gap-4 sm:grid-cols-2">
        <Stat label="Upcoming exams" value={upcoming.length} />
        <Stat label="Draft exams" value={drafts} />
      </div>
      <Card title="Upcoming exams in your subjects">
        {upcoming.length === 0 ? (
          <p className="text-sm text-slate-500">No upcoming published exams in your subjects.</p>
        ) : (
          <ul className="divide-y divide-slate-100">
            {upcoming.map((e) => (
              <li key={e.id} data-testid="home-exam" className="flex flex-wrap items-center justify-between gap-2 py-3 text-sm">
                <span>
                  <span className="font-medium text-slate-900">{e.title}</span>
                  <span className="ml-2 text-slate-500">
                    {e.subject} · {e.paper} · {formatLondon(e.startsAt)}
                  </span>
                </span>
                <span data-testid="home-seats" className="text-slate-700">
                  {e.seatsBooked} of {e.seatLimit} seats booked
                </span>
              </li>
            ))}
          </ul>
        )}
      </Card>
      <div className="flex gap-4 text-sm">
        <Link href="/teacher/exams" className="font-medium text-blue-700 underline">
          Manage exams
        </Link>
        <Link href="/teacher/attendance" className="font-medium text-blue-700 underline">
          Attendance registers
        </Link>
      </div>
    </div>
  );
}

export default function TeacherHome() {
  return (
    <AppShell role="teacher" title="Teacher">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading...</p>}>
        <Body />
      </Suspense>
    </AppShell>
  );
}
