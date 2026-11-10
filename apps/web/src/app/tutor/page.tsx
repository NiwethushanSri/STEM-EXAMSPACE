import { Suspense } from "react";
import { AppShell, Badge, Card } from "@/components/AppShell";
import { STATUS_LABEL, STATUS_TONE } from "@/components/bookings/status";
import { formatLondon } from "@/lib/money";
import { loadTutorHome } from "@/lib/staff-homes";

async function Body() {
  const { rows, students, capped } = await loadTutorHome();
  return (
    <Card title="Upcoming bookings of your students">
      {students === 0 ? (
        <p className="text-sm text-slate-500">No students are assigned to you yet.</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-slate-500">None of your students has an upcoming booking.</p>
      ) : (
        <ul className="divide-y divide-slate-100">
          {rows.map((r) => (
            <li key={r.id} data-testid="tutor-booking" className="flex flex-wrap items-center justify-between gap-2 py-3 text-sm">
              <span>
                <span className="font-medium text-slate-900">{r.student}</span>
                <span className="ml-2 text-slate-500">
                  {r.exam ? `${r.exam.subject} · ${formatLondon(r.exam.startsAt)}` : "Exam details unavailable"}
                </span>
              </span>
              <Badge tone={STATUS_TONE[r.status]}>{STATUS_LABEL[r.status]}</Badge>
            </li>
          ))}
        </ul>
      )}
      {capped && <p className="mt-3 text-xs text-slate-500">Showing the first 200 bookings.</p>}
    </Card>
  );
}

export default function TutorHome() {
  return (
    <AppShell role="tutor" title="Tutor">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading...</p>}>
        <Body />
      </Suspense>
    </AppShell>
  );
}
