"use client";

import { useState, useTransition } from "react";
import { Badge, Card } from "@/components/AppShell";
import { ExamForm } from "@/components/exams/ExamForm";
import { saveTeacherExamAction, type TeacherExamResult } from "@/app/teacher/exams/actions";
import type { ExamRow, SubjectOption, VenueOption } from "@/lib/exams-staff";
import { formatLondon } from "@/lib/money";

const STATUS_TONE = { draft: "slate", published: "green", cancelled: "red", completed: "blue" } as const;
const STATUS_LABEL = { draft: "Draft", published: "Published", cancelled: "Cancelled", completed: "Completed" } as const;

/** A teacher's exams: their own subjects only; drafts can be created and edited, nothing else. No price, no publish. */
export function TeacherExams({ exams, subjects, venues }: { exams: ExamRow[]; subjects: SubjectOption[]; venues: VenueOption[] }) {
  const [editing, setEditing] = useState<ExamRow | "new" | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [, startTransition] = useTransition();

  function save(raw: Record<string, string>) {
    setBusy(true);
    setFormError(null);
    setNotice(null);
    startTransition(async () => {
      let res: TeacherExamResult;
      try {
        res = await saveTeacherExamAction(raw);
      } catch {
        res = { ok: false, message: "Something went wrong. Please try again." };
      }
      setBusy(false);
      if (res.ok) {
        setEditing(null);
        setNotice(res.message);
      } else {
        setFormError(res.message);
      }
    });
  }

  if (subjects.length === 0) {
    return (
      <Card>
        <p className="text-sm text-slate-600">You are not assigned to any subjects yet. Ask an admin to assign them, then you can draft exams here.</p>
      </Card>
    );
  }

  return (
    <div className="space-y-5">
      {notice && (
        <div role="status" className="rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">{notice}</div>
      )}
      <div className="flex items-center justify-between gap-3">
        <p className="text-sm text-slate-600">
          Your subjects: {subjects.map((s) => s.name).join(", ")}. You draft exams here; an admin sets the price and publishes them.
        </p>
        <button
          type="button"
          onClick={() => {
            setFormError(null);
            setNotice(null);
            setEditing("new");
          }}
          className="shrink-0 rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
        >
          New draft exam
        </button>
      </div>

      {editing && (
        <ExamForm
          key={editing === "new" ? "new" : editing.id}
          withPrice={false}
          subjects={subjects}
          venues={venues}
          exam={editing === "new" ? null : editing}
          busy={busy}
          error={formError}
          onSubmit={save}
          onCancel={() => setEditing(null)}
        />
      )}

      <Card title="Exams in your subjects">
        {exams.length === 0 ? (
          <p className="text-sm text-slate-500">No exams yet in your subjects.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  {["When (UK time)", "Exam", "Where", "Status", "Seat limit", "Actions"].map((h) => (
                    <th key={h} className="py-2 pr-4 font-medium">{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {exams.map((e) => (
                  <tr key={e.id} data-testid="exam-row" className="border-b border-slate-100 align-top last:border-0">
                    <td className="py-2.5 pr-4 whitespace-nowrap">{formatLondon(e.startsAt)}</td>
                    <td className="py-2.5 pr-4">
                      <div className="font-medium text-slate-900">{e.title}</div>
                      <div className="text-xs text-slate-500">
                        {e.subject}
                        {e.paper ? ` · ${e.paper}` : ""} · {e.durationMinutes} min
                      </div>
                    </td>
                    <td className="py-2.5 pr-4">{e.format === "online" ? "Online" : [e.venue, e.room].filter(Boolean).join(" · ")}</td>
                    <td className="py-2.5 pr-4"><Badge tone={STATUS_TONE[e.status]}>{STATUS_LABEL[e.status]}</Badge></td>
                    <td className="py-2.5 pr-4">{e.seatLimit}</td>
                    <td className="py-2.5">
                      {e.status === "draft" ? (
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() => {
                            setFormError(null);
                            setNotice(null);
                            setEditing(e);
                          }}
                          className="rounded border border-slate-300 px-3 py-1 text-xs hover:bg-slate-50 disabled:opacity-60"
                        >
                          Edit
                        </button>
                      ) : (
                        <span className="text-xs text-slate-500">Only drafts can be edited</span>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
