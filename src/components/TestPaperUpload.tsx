"use client";

import Link from "next/link";
import { useState } from "react";
import { Card } from "@/components/AppShell";
import { loadPapers, savePapers, saveFile, type StudentPaper } from "@/lib/papers";

// Adds a paper to the marking queue without a student, for test marking.
export function TestPaperUpload({ onAdded }: { onAdded: (paper: StudentPaper) => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [last, setLast] = useState<StudentPaper | null>(null);

  async function handleFile(file: File) {
    setBusy(true);
    setError(null);
    try {
      const body = new FormData();
      body.append("file", file);
      const res = await fetch("/api/papers/read", { method: "POST", body });
      if (!res.ok) throw new Error("read failed");
      const reading = (await res.json()) as { questions: StudentPaper["questions"]; hasTextLayer: boolean };

      if (reading.questions.length === 0) {
        setError("No questions were found in this PDF. Only typed papers can be marked by question for now.");
        return;
      }

      const paper: StudentPaper = {
        id: `test-${Date.now()}`,
        fileName: file.name,
        examTitle: file.name.replace(/\.pdf$/i, ""),
        indexNumber: "",
        candidateName: "Test candidate",
        studentId: "",
        uploadedAt: new Date().toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" }),
        status: "Awaiting marking",
        questions: reading.questions,
        marks: {},
        feedback: "",
      };
      savePapers([...loadPapers(), paper]);
      const stored = await saveFile(paper.id, file);
      setLast(paper);
      onAdded(paper);
      if (!stored) {
        setError("The paper was added, but its PDF could not be saved in this browser, so the viewer will be empty.");
      }
    } catch {
      setError("This PDF could not be read.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card title="Upload a test paper to mark">
      <p className="mb-4 text-sm text-slate-600">
        Pick a typed PDF. Its questions are found automatically and it is added to the marking queue, with no
        student attached.
      </p>
      <label
        className={`flex cursor-pointer flex-col items-center justify-center rounded-xl border-2 border-dashed px-6 py-8 text-center ${
          busy ? "border-slate-300 bg-slate-50" : "border-blue-300 bg-blue-50/50 hover:border-blue-500"
        }`}
      >
        <span className="font-semibold text-blue-800">{busy ? "Reading paper…" : "Choose PDF to mark"}</span>
        <input
          type="file"
          accept="application/pdf"
          className="sr-only"
          disabled={busy}
          onChange={(e) => {
            const file = e.target.files?.[0];
            if (file) handleFile(file);
            e.target.value = "";
          }}
        />
      </label>

      {error && <p className="mt-4 rounded-lg bg-red-50 px-4 py-3 text-sm text-red-700">{error}</p>}
      {last && (
        <p className="mt-4 rounded-lg bg-green-50 px-4 py-3 text-sm text-green-800">
          {last.examTitle} is ready. <Link href={`/examiner/papers/${last.id}`} className="font-semibold underline">Mark it now</Link>
        </p>
      )}
    </Card>
  );
}
