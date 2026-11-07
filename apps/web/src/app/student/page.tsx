"use client";

import { useEffect, useState } from "react";
import { AppShell, Card, Stat, Badge } from "@/components/AppShell";
import { AlertsPanel } from "@/components/AlertsPanel";
import { DEMO_CHILD_ID, getNotices, getTimetable, upcomingExams, type Exam, type Notice } from "@/lib/alerts";
import { results, student } from "@/lib/site-data";

export default function StudentDashboard() {
  // Exams and notices come from the saved calendar, so changes by admin show here straight away.
  const [exams, setExams] = useState<Exam[]>([]);
  const [notices, setNotices] = useState<Notice[]>([]);

  useEffect(() => {
    setExams(upcomingExams(getTimetable()));
    setNotices(getNotices());
  }, []);

  const avg = Math.round(results.reduce((s, r) => s + r.mark, 0) / results.length);
  const weak = results.flatMap((r) => r.weakAreas);
  const next = exams[0];

  return (
    <AppShell role="student" title={`Welcome, ${student.name.split(" ")[0]}`}>
      <div className="grid gap-4 md:grid-cols-3">
        <Stat label="Average mark" value={`${avg}%`} />
        <Stat label="Tests taken" value={results.length} />
        <Stat label="Next exam" value={next ? `${next.subject}, ${next.date}` : "None scheduled"} />
      </div>
      <div className="mt-6">
        <AlertsPanel audience="student" childId={DEMO_CHILD_ID} />
      </div>
      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <Card title="Upcoming exams">
          {exams.length === 0 ? (
            <p className="py-4 text-center text-sm text-slate-500">No exams scheduled.</p>
          ) : (
            <ul className="divide-y divide-slate-100 text-sm">
              {exams.map((e) => (
                <li key={`${e.subject}-${e.date}`} className="flex items-center justify-between py-2.5">
                  <span>
                    <span className="font-medium">{e.subject}</span> · {e.date} {e.time}
                  </span>
                  <Badge tone={e.type === "Online" ? "blue" : "amber"}>{e.type}</Badge>
                </li>
              ))}
            </ul>
          )}
        </Card>
        <Card title="Topics to work on">
          <ul className="list-disc space-y-1 pl-5 text-sm">
            {weak.map((w) => (
              <li key={w}>{w}</li>
            ))}
          </ul>
        </Card>
        <Card title="Latest notices">
          <ul className="space-y-3 text-sm">
            {notices.map((n) => (
              <li key={n.id}>
                <div className="font-medium">{n.title}</div>
                <div className="text-xs text-slate-500">{n.date} · {n.type}</div>
              </li>
            ))}
          </ul>
        </Card>
      </div>
    </AppShell>
  );
}
