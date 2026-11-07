"use client";

import { useEffect, useState } from "react";
import { AppShell, Card, Stat, Badge } from "@/components/AppShell";
import { AlertsPanel } from "@/components/AlertsPanel";
import { DEMO_CHILD_ID, getTimetable, upcomingExams, type Exam } from "@/lib/alerts";
import { results, attendance, student } from "@/lib/site-data";

export default function ParentDashboard() {
  // Exams come from the saved calendar, so changes by admin show here straight away.
  const [exams, setExams] = useState<Exam[]>([]);

  useEffect(() => {
    setExams(upcomingExams(getTimetable()));
  }, []);

  const present = attendance.filter((a) => a.status === "Present").length;
  const avg = Math.round(results.reduce((s, r) => s + r.mark, 0) / results.length);
  const next = exams[0];

  return (
    <AppShell role="parent" title={`${student.name}'s progress`}>
      <div className="grid gap-4 md:grid-cols-3">
        <Stat label="Average mark" value={`${avg}%`} />
        <Stat label="Attendance" value={`${present} of ${attendance.length} exams`} />
        <Stat label="Next exam" value={next ? `${next.subject}, ${next.date}` : "None scheduled"} />
      </div>
      <div className="mt-6">
        <AlertsPanel audience="parent" childId={DEMO_CHILD_ID} />
      </div>
      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <Card title="Recent results">
          <ul className="divide-y divide-slate-100 text-sm">
            {results.map((r) => (
              <li key={r.subject} className="flex items-center justify-between py-2.5">
                <span>
                  <span className="font-medium">{r.subject}</span> · {r.test}
                </span>
                <span className="font-semibold">{r.mark}%</span>
              </li>
            ))}
          </ul>
        </Card>
        <Card title="Upcoming exams">
          {exams.length === 0 ? (
            <p className="py-4 text-center text-sm text-slate-500">No exams scheduled.</p>
          ) : (
            <ul className="divide-y divide-slate-100 text-sm">
              {exams.map((e) => (
                <li key={`${e.subject}-${e.date}`} className="flex items-center justify-between py-2.5">
                  <span>{e.subject} · {e.date} {e.time}</span>
                  <Badge tone={e.type === "Online" ? "blue" : "amber"}>{e.type}</Badge>
                </li>
              ))}
            </ul>
          )}
        </Card>
      </div>
    </AppShell>
  );
}
