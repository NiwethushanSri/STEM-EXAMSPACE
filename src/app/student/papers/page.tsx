"use client";

import { useEffect, useState } from "react";
import { AppShell, Card, Badge, Table } from "@/components/AppShell";
import { loadPapers, NO_RESPONSE, type StudentPaper } from "@/lib/papers";

// Mockup: the signed-in student is Amara Perera until real sign-in is built.
const SIGNED_IN_STUDENT_ID = "amara-perera";

export default function StudentPapers() {
  const [papers, setPapers] = useState<StudentPaper[]>([]);

  useEffect(() => {
    setPapers(loadPapers().filter((p) => p.studentId === SIGNED_IN_STUDENT_ID));
  }, []);

  return (
    <AppShell role="student" title="My papers">
      {papers.length === 0 ? (
        <Card>
          <p className="py-6 text-center text-sm text-slate-500">
            No papers yet. Your papers appear here once Stem Examspace has uploaded them.
          </p>
        </Card>
      ) : (
        <div className="space-y-6">
          {papers.map((p) => {
            const total = p.questions.reduce((s, q) => s + q.max, 0);
            const got = p.questions.reduce((s, q) => s + Math.max(0, p.marks[q.id] ?? 0), 0);
            const marked = p.status === "Marked";
            return (
              <Card key={p.id}>
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div>
                    <h2 className="font-semibold text-slate-900">{p.examTitle}</h2>
                    <p className="text-xs text-slate-500">Uploaded {p.uploadedAt}</p>
                  </div>
                  <div className="flex items-center gap-3">
                    {marked ? <Badge tone="green">Marked</Badge> : <Badge tone="amber">Awaiting marking</Badge>}
                    {marked && <span className="text-2xl font-semibold text-blue-700">{got} / {total}</span>}
                  </div>
                </div>

                {marked && p.questions.length > 0 && (
                  <div className="mt-4">
                    <Table
                      head={["Question", "Mark", "Out of"]}
                      rows={p.questions.map((q) => {
                        const v = p.marks[q.id];
                        return [q.label, v === undefined ? "—" : v === NO_RESPONSE ? "NR" : v, q.max];
                      })}
                    />
                  </div>
                )}

                {marked && p.feedback && (
                  <div className="mt-4 rounded-lg bg-blue-50 p-4 text-sm text-slate-700">
                    <div className="mb-1 font-medium text-blue-800">Examiner feedback</div>
                    {p.feedback}
                  </div>
                )}
              </Card>
            );
          })}
        </div>
      )}
    </AppShell>
  );
}
