"use client";

import { useEffect, useRef, useState } from "react";
import { Badge, Card } from "@/components/AppShell";
import { matchStudent, loadPapers, savePapers, saveFile, type StudentPaper, type MatchResult, type PaperQuestion } from "@/lib/papers";
import { inputClass, labelClass } from "@/components/AuthLayout";

type Row = {
  key: string;
  fileName: string;
  sizeKb: number;
  examTitle: string;
  indexNumber: string;
  candidateName: string;
  state: "reading" | "done" | "error";
  hasTextLayer: boolean;
  questions: PaperQuestion[];
};

function badgeFor(row: Row, match: MatchResult) {
  if (row.state === "reading") return <Badge tone="slate">Reading paper…</Badge>;
  if (row.state === "error") return <Badge tone="red">Could not read this PDF</Badge>;
  switch (match.status) {
    case "matched":
      return <Badge tone="green">Matched to {match.child.name}</Badge>;
    case "name-mismatch":
      return <Badge tone="amber">Name differs from {match.child.name}</Badge>;
    case "no-index":
      return <Badge tone="red">No student with this index</Badge>;
    default:
      return <Badge tone="slate">Enter candidate number</Badge>;
  }
}

async function readFile(file: File) {
  const body = new FormData();
  body.append("file", file);
  const res = await fetch("/api/papers/read", { method: "POST", body });
  if (!res.ok) throw new Error("read failed");
  return (await res.json()) as {
    hasTextLayer: boolean;
    candidateNumber: string;
    candidateName: string;
    questions: PaperQuestion[];
  };
}

export function PaperUpload() {
  const [rows, setRows] = useState<Row[]>([]);
  const [papers, setPapers] = useState<StudentPaper[]>([]);
  const [message, setMessage] = useState<string | null>(null);
  // The original files, kept until the papers are assigned so their PDFs can be stored.
  const fileStore = useRef(new Map<string, File>());

  useEffect(() => {
    setPapers(loadPapers());
  }, []);

  function patchRow(key: string, patch: Partial<Row>) {
    setRows((r) => r.map((row) => (row.key === key ? { ...row, ...patch } : row)));
  }

  async function addFiles(files: FileList | null) {
    if (!files) return;
    const picked = Array.from(files);
    const added: Row[] = picked.map((f, i) => ({
      key: `${Date.now()}-${i}-${f.name}`,
      fileName: f.name,
      sizeKb: Math.round(f.size / 1024),
      examTitle: f.name.replace(/\.pdf$/i, ""),
      indexNumber: "",
      candidateName: "",
      state: "reading",
      hasTextLayer: false,
      questions: [],
    }));
    setRows((r) => [...r, ...added]);
    setMessage(null);

    // Read each paper: this fills in candidate details and the question list.
    await Promise.all(
      picked.map(async (file, i) => {
        const key = added[i].key;
        fileStore.current.set(key, file);
        try {
          const reading = await readFile(file);
          patchRow(key, {
            state: "done",
            hasTextLayer: reading.hasTextLayer,
            indexNumber: reading.candidateNumber,
            candidateName: reading.candidateName,
            questions: reading.questions,
          });
        } catch {
          patchRow(key, { state: "error" });
        }
      })
    );
  }

  function update(key: string, field: "indexNumber" | "candidateName" | "examTitle", value: string) {
    setRows((r) => r.map((row) => (row.key === key ? { ...row, [field]: value } : row)));
  }

  function remove(key: string) {
    setRows((r) => r.filter((row) => row.key !== key));
  }

  const matchOf = (r: Row) => matchStudent(r.indexNumber, r.candidateName);
  const ready = rows.filter((r) => r.state === "done" && matchOf(r).status === "matched");

  async function assignMatched() {
    const now = new Date().toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
    const created: StudentPaper[] = ready.map((r) => {
      const result = matchOf(r);
      const matched = result.status === "matched" ? result.child : undefined;
      return {
        id: r.key,
        fileName: r.fileName,
        examTitle: r.examTitle || r.fileName,
        indexNumber: matched?.indexNumber ?? r.indexNumber,
        candidateName: matched?.name ?? r.candidateName,
        studentId: matched?.id ?? "",
        uploadedAt: now,
        status: "Awaiting marking",
        questions: r.questions,
        marks: {},
        feedback: "",
      };
    });
    const next = [...papers, ...created];
    savePapers(next);
    setPapers(next);
    let unstored = 0;
    for (const r of ready) {
      const file = fileStore.current.get(r.key);
      if (file && !(await saveFile(r.key, file))) unstored++;
      fileStore.current.delete(r.key);
    }
    setRows((rs) => rs.filter((row) => !ready.includes(row)));
    if (unstored > 0) {
      setMessage(`${created.length} paper(s) assigned, but ${unstored} PDF(s) could not be saved in this browser.`);
      return;
    }
    setMessage(`${created.length} paper${created.length === 1 ? "" : "s"} assigned. They now show in the examiner and student portals.`);
  }

  return (
    <div className="space-y-6">
      <Card title="1. Add student papers (PDF)">
        <label className="flex cursor-pointer flex-col items-center justify-center rounded-xl border-2 border-dashed border-blue-300 bg-blue-50/50 px-6 py-10 text-center hover:border-blue-500">
          <span className="font-semibold text-blue-800">Choose PDF files</span>
          <span className="mt-1 text-sm text-slate-500">The page reads the cover and questions automatically</span>
          <input
            type="file"
            accept="application/pdf"
            multiple
            className="sr-only"
            onChange={(e) => {
              addFiles(e.target.files);
              e.target.value = "";
            }}
          />
        </label>
      </Card>

      {rows.length > 0 && (
        <Card title="2. Check each paper against the student">
          <p className="mb-4 text-sm text-slate-600">
            Candidate details are read from the cover when they are typed on the paper. For a handwritten
            scan, type the candidate number and name. Papers match by index number first, then the name.
          </p>
          <div className="space-y-4">
            {rows.map((r) => {
              const match = matchOf(r);
              return (
                <div key={r.key} className="rounded-xl border border-slate-200 p-4">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <div className="font-medium text-slate-900">
                      {r.fileName} <span className="text-xs font-normal text-slate-500">· {r.sizeKb} KB</span>
                    </div>
                    <div className="flex items-center gap-3">
                      {badgeFor(r, match)}
                      <button type="button" onClick={() => remove(r.key)} className="text-xs text-slate-500 hover:text-red-600">
                        Remove
                      </button>
                    </div>
                  </div>

                  {r.state === "done" && (
                    <p className="mt-2 text-xs text-slate-500">
                      {r.questions.length} question{r.questions.length === 1 ? "" : "s"} found
                      {r.hasTextLayer ? "" : " · no typed text found, so this looks like a handwritten scan"}
                    </p>
                  )}

                  <div className="mt-3 grid gap-3 md:grid-cols-3">
                    <div>
                      <label className={labelClass}>Candidate number</label>
                      <input
                        className={inputClass}
                        placeholder="SE-2026-0142"
                        value={r.indexNumber}
                        onChange={(e) => update(r.key, "indexNumber", e.target.value)}
                      />
                    </div>
                    <div>
                      <label className={labelClass}>Candidate name</label>
                      <input
                        className={inputClass}
                        placeholder="Amara Perera"
                        value={r.candidateName}
                        onChange={(e) => update(r.key, "candidateName", e.target.value)}
                      />
                    </div>
                    <div>
                      <label className={labelClass}>Exam title</label>
                      <input className={inputClass} value={r.examTitle} onChange={(e) => update(r.key, "examTitle", e.target.value)} />
                    </div>
                  </div>
                </div>
              );
            })}
          </div>

          <div className="mt-6 flex flex-wrap items-center justify-between gap-3">
            <span className="text-sm text-slate-600">
              {ready.length} of {rows.length} ready to assign
            </span>
            <button
              type="button"
              disabled={ready.length === 0}
              onClick={assignMatched}
              className="rounded-lg bg-blue-600 px-5 py-2.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-slate-300"
            >
              Assign matched papers
            </button>
          </div>
        </Card>
      )}

      {message && <p className="rounded-lg bg-green-50 px-4 py-3 text-sm text-green-800">{message}</p>}

      <p className="text-sm text-slate-500">
        {papers.length} paper{papers.length === 1 ? "" : "s"} assigned so far.
      </p>
    </div>
  );
}
