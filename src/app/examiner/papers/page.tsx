"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { AppShell, Card, Table, Badge, Stat } from "@/components/AppShell";
import { loadPapers, type StudentPaper } from "@/lib/papers";
import { TestPaperUpload } from "@/components/TestPaperUpload";

export default function ExaminerPapers() {
  const [papers, setPapers] = useState<StudentPaper[]>([]);

  useEffect(() => {
    setPapers(loadPapers());
  }, []);

  const waiting = papers.filter((p) => p.status === "Awaiting marking").length;
  const students = new Set(papers.filter((p) => p.studentId).map((p) => p.studentId)).size;

  return (
    <AppShell role="examiner" title="Student papers">
      <div className="mb-6">
        <TestPaperUpload onAdded={(paper) => setPapers((list) => [...list, paper])} />
      </div>

      <div className="grid gap-4 md:grid-cols-3">
        <Stat label="Papers in queue" value={papers.length} />
        <Stat label="Awaiting marking" value={waiting} />
        <Stat label="Students" value={students} />
      </div>

      <div className="mt-6">
        <Card title="Papers by student">
          {papers.length === 0 ? (
            <p className="py-6 text-center text-sm text-slate-500">
              No papers yet. Admin uploads them from the Upload student papers page.
            </p>
          ) : (
            <Table
              head={["Student", "Index number", "Paper", "Uploaded", "Total", "Status", "Action"]}
              rows={papers.map((p) => [
                <span key={`${p.id}-n`} className="font-medium">{p.candidateName}</span>,
                p.indexNumber || "—",
                p.examTitle,
                p.uploadedAt,
                // Total from the marks entered in the side panel, out of the paper's maximum.
                p.questions.length === 0 ? "—" : (
                  <span key={`${p.id}-t`} className="font-semibold text-blue-700">
                    {p.questions.reduce((s, q) => s + Math.max(0, p.marks[q.id] ?? 0), 0)}
                    <span className="font-normal text-slate-500"> / {p.questions.reduce((s, q) => s + q.max, 0)}</span>
                  </span>
                ),
                <Badge key={`${p.id}-s`} tone={p.status === "Marked" ? "green" : "amber"}>{p.status}</Badge>,
                <Link key={`${p.id}-a`} href={`/examiner/papers/${p.id}`} className="text-blue-700 underline">
                  Mark paper
                </Link>,
              ])}
            />
          )}
        </Card>
      </div>
    </AppShell>
  );
}
