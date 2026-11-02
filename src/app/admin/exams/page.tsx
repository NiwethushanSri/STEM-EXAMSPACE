"use client";

import { useEffect, useState, type FormEvent } from "react";
import { AppShell, Card, Table, Badge } from "@/components/AppShell";
import { inputClass, labelClass } from "@/components/AuthLayout";
import { getTimetable, updateExam, type Exam } from "@/lib/alerts";
import { subjects, entranceExams } from "@/lib/site-data";

// "2026-11-14" from the date input becomes "14 Nov 2026", the format the calendar uses.
function toDisplay(iso: string) {
  return new Date(`${iso}T00:00`).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
}

export default function AdminExams() {
  const [timetable, setTimetable] = useState<Exam[]>([]);
  const [subject, setSubject] = useState("");
  const [date, setDate] = useState("");
  const [time, setTime] = useState("");
  const [message, setMessage] = useState("");

  useEffect(() => {
    const list = getTimetable();
    setTimetable(list);
    setSubject(list[0]?.subject ?? "");
  }, []);

  // Saving a calendar change alerts every student and parent.
  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (!subject || !date || !time) return;
    const recipients = updateExam(subject, toDisplay(date), time);
    setTimetable(getTimetable());
    setDate("");
    setTime("");
    setMessage(`${subject} updated. Alert sent to ${recipients} students and ${recipients} parents.`);
  }

  return (
    <AppShell role="admin" title="Exams & timetable">
      <div className="mb-4 flex items-center justify-between gap-3">
        <p className="text-sm text-green-700">{message}</p>
      </div>
      <div className="grid gap-4 lg:grid-cols-3">
        <Card title="Subjects">
          <ul className="space-y-1 text-sm">
            {[...subjects, ...entranceExams].map((s) => (
              <li key={s} className="border-b border-slate-100 py-1.5 last:border-0">{s}</li>
            ))}
          </ul>
        </Card>
        <div className="space-y-4 lg:col-span-2">
          <Card title="Update an exam date">
            <form onSubmit={submit} className="grid gap-3 sm:grid-cols-4">
              <div className="sm:col-span-2">
                <label className={labelClass}>Subject</label>
                <select value={subject} onChange={(e) => setSubject(e.target.value)} className={inputClass}>
                  {timetable.map((t) => (
                    <option key={t.subject}>{t.subject}</option>
                  ))}
                </select>
              </div>
              <div>
                <label className={labelClass}>New date</label>
                <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={inputClass} required />
              </div>
              <div>
                <label className={labelClass}>Time</label>
                <input type="time" value={time} onChange={(e) => setTime(e.target.value)} className={inputClass} required />
              </div>
              <div className="sm:col-span-4 flex justify-end">
                <button type="submit" className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700">
                  Save and alert students and parents
                </button>
              </div>
            </form>
          </Card>
          <Card title="Timetable">
            <Table
              head={["Date", "Subject", "Time", "Format", "Paper allocation"]}
              rows={timetable.map((t) => [
                t.date,
                t.subject,
                t.time,
                <Badge key={t.subject} tone={t.type === "Online" ? "blue" : "amber"}>{t.type}</Badge>,
                t.type === "Physical" ? "Physical papers" : "Online",
              ])}
            />
          </Card>
        </div>
      </div>
    </AppShell>
  );
}
