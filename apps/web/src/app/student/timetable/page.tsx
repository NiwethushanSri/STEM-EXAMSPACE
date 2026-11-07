"use client";

import { useEffect, useState } from "react";
import { AppShell, Card, Table, Badge } from "@/components/AppShell";
import { getTimetable, type Exam } from "@/lib/alerts";

export default function StudentTimetable() {
  // The calendar is read from the saved timetable, so admin changes show here straight away.
  const [timetable, setTimetable] = useState<Exam[]>([]);

  useEffect(() => {
    setTimetable(getTimetable());
  }, []);

  return (
    <AppShell role="student" title="Exam timetable">
      <Card title="Upcoming exams (June 2027 mock series)">
        <Table
          head={["Date", "Subject", "Time", "Format"]}
          rows={timetable.map((t) => [
            t.date,
            t.subject,
            t.time,
            <Badge key={t.subject} tone={t.type === "Online" ? "blue" : "amber"}>{t.type}</Badge>,
          ])}
        />
      </Card>
    </AppShell>
  );
}
