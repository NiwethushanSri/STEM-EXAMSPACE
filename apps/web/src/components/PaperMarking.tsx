"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { Badge } from "@/components/AppShell";
import { loadPapers, loadFile, savePapers, NO_RESPONSE, type StudentPaper } from "@/lib/papers";
import { PdfViewer, Stamp } from "@/components/PdfViewer";
import { inputClass } from "@/components/AuthLayout";
import { loadAnnotations, saveAnnotations, STAMP_KINDS, TOOL_LABELS, type Annotation, type Tool } from "@/lib/annotations";

const DRAW_TOOLS: Exclude<Tool, "select">[] = ["pen", "highlight", "ruler", "box", "protractor", "text"];

const HINTS: Partial<Record<Tool, string>> = {
  pen: "Draw on the paper",
  highlight: "Highlight on the paper",
  ruler: "Drag to measure a length in cm",
  box: "Drag to draw a box with its size in cm",
  protractor: "Click the vertex, then a point on each arm",
  text: "Click the paper, or drag onto it",
};

export function PaperMarking({ paperId }: { paperId: string }) {
  const [paper, setPaper] = useState<StudentPaper | null | undefined>(undefined);
  const [bytes, setBytes] = useState<Uint8Array | null>(null);
  const [active, setActive] = useState(0);
  const [saved, setSaved] = useState(false);
  const [tool, setTool] = useState<Tool>("select");
  const [annotations, setAnnotations] = useState<Annotation[]>([]);

  useEffect(() => {
    setPaper(loadPapers().find((p) => p.id === paperId) ?? null);
    setBytes(loadFile(paperId));
    setAnnotations(loadAnnotations(paperId));
  }, [paperId]);

  function changeAnnotations(next: Annotation[]) {
    setAnnotations(next);
    saveAnnotations(paperId, next);
  }

  if (paper === undefined) return <p className="text-sm text-slate-500">Loading paper…</p>;
  if (paper === null) {
    return (
      <div className="rounded-xl bg-white p-6 shadow-sm">
        <p className="text-sm text-slate-600">This paper was not found in this browser.</p>
        <Link href="/examiner/papers" className="mt-3 inline-block text-sm text-blue-700 underline">Back to papers</Link>
      </div>
    );
  }

  const questions = paper.questions;
  const got = (qid: string) => Math.max(0, paper.marks[qid] ?? 0);
  const totalMax = questions.reduce((s, q) => s + q.max, 0);
  const totalMarks = questions.reduce((s, q) => s + got(q.id), 0);
  const markedCount = questions.filter((q) => paper.marks[q.id] !== undefined).length;

  function update(next: Partial<StudentPaper>) {
    setPaper((p) => (p ? { ...p, ...next } : p));
    setSaved(false);
  }

  // Number pad: sets the mark for the selected question. NR means no response.
  function pick(value: number | null) {
    if (!paper || questions.length === 0) return;
    const qid = questions[active].id;
    if (value === null) {
      const { [qid]: _cleared, ...rest } = paper.marks;
      update({ marks: rest });
    } else {
      update({ marks: { ...paper.marks, [qid]: value } });
    }
  }

  function save() {
    if (!paper) return;
    const allMarked = questions.length > 0 && markedCount === questions.length;
    const updated: StudentPaper = { ...paper, status: allMarked ? "Marked" : "Awaiting marking" };
    savePapers(loadPapers().map((p) => (p.id === updated.id ? updated : p)));
    setPaper(updated);
    setSaved(true);
  }

  if (questions.length === 0) {
    return (
      <div className="rounded-xl bg-white p-6 shadow-sm">
        <p className="text-sm text-slate-600">
          No questions were found in this paper, so it cannot be marked by question yet.
        </p>
      </div>
    );
  }

  const q = questions[active];
  const current = paper.marks[q.id];

  return (
    <div className="flex flex-col gap-4">
      {/* Header */}
      <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl bg-white px-5 py-3 shadow-sm">
        <div className="text-sm">
          <span className="font-semibold text-slate-900">{paper.examTitle}</span>
          <span className="ml-3 text-slate-500">{paper.candidateName}{paper.indexNumber ? ` · ${paper.indexNumber}` : ""}</span>
        </div>
        <div className="flex items-center gap-4 text-sm">
          <span>
            Total <span className="text-lg font-semibold text-blue-700">{totalMarks}</span>
            <span className="text-slate-500"> / {totalMax}</span>
          </span>
          {markedCount === questions.length ? <Badge tone="green">All marked</Badge> : <Badge tone="amber">{markedCount} / {questions.length} marked</Badge>}
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-[1fr_300px]">
        {/* Paper */}
        <div className="flex h-[72vh] min-h-[480px] flex-col overflow-hidden rounded-xl bg-white shadow-sm">
          {/* Marking tools: click a tool then click the paper, or drag a mark onto the paper */}
          <div className="flex flex-wrap items-center gap-2 border-b border-slate-200 px-3 py-2">
            <button
              type="button"
              onClick={() => setTool("select")}
              className={`rounded-lg px-3 py-1.5 text-sm ${tool === "select" ? "bg-blue-600 text-white" : "border border-slate-300 text-slate-700"}`}
            >
              Select
            </button>
            {/* Stamps: RM-style symbols and boxed codes. Click, or drag onto the paper. */}
            <div className="flex flex-wrap items-center gap-1">
              {STAMP_KINDS.map((t) => (
                <button
                  key={t}
                  type="button"
                  draggable
                  onDragStart={(e) => e.dataTransfer.setData("text/plain", t)}
                  onClick={() => setTool(t)}
                  title={`${TOOL_LABELS[t]}: click the paper, or drag onto it`}
                  aria-label={TOOL_LABELS[t]}
                  className={`flex h-9 min-w-9 items-center justify-center rounded-lg px-1.5 ${tool === t ? "bg-blue-100 ring-2 ring-blue-600" : "border border-slate-200 hover:bg-slate-50"}`}
                >
                  <Stamp kind={t} />
                </button>
              ))}
            </div>
            <span className="h-6 w-px bg-slate-300" />
            {/* Drawing tools: freehand red pen, highlighter, and red notes */}
            {DRAW_TOOLS.map((t) => (
              <button
                key={t}
                type="button"
                draggable={t === "text"}
                onDragStart={(e) => e.dataTransfer.setData("text/plain", t)}
                onClick={() => setTool(t)}
                title={HINTS[t]}
                className={`rounded-lg px-3 py-1.5 text-sm ${tool === t ? "bg-blue-600 text-white" : "border border-slate-300 text-slate-700"}`}
              >
                {TOOL_LABELS[t]}
              </button>
            ))}
            <button
              type="button"
              disabled={annotations.length === 0}
              onClick={() => changeAnnotations(annotations.slice(0, -1))}
              className="ml-auto rounded-lg border border-slate-300 px-3 py-1.5 text-sm text-slate-700 disabled:opacity-40"
            >
              Undo
            </button>
          </div>
          <div className="min-h-0 flex-1 overflow-hidden">
          {bytes ? (
            <PdfViewer bytes={bytes} tool={tool} annotations={annotations} onAnnotationsChange={changeAnnotations} />
          ) : (
            <p className="p-6 text-sm text-slate-500">
              The PDF for this paper is not stored in this browser. Upload it again to see it here.
            </p>
          )}
          </div>
        </div>

        {/* Marking panel */}
        <div className="flex h-[72vh] min-h-[480px] flex-col overflow-hidden rounded-xl bg-white shadow-sm">
          <div className="border-b border-slate-200 px-4 py-3 text-sm font-semibold text-blue-800">Questions</div>

          <ul className="flex-1 overflow-y-auto">
            {questions.map((question, i) => {
              const value = paper.marks[question.id];
              const isActive = i === active;
              return (
                <li key={question.id}>
                  <button
                    type="button"
                    onClick={() => setActive(i)}
                    className={`flex w-full items-center justify-between px-4 py-2.5 text-sm ${
                      isActive ? "bg-blue-600 text-white" : "hover:bg-blue-50"
                    }`}
                  >
                    <span className="font-medium">{question.label}</span>
                    <span className={isActive ? "text-blue-100" : value === undefined ? "text-slate-400" : "font-medium text-slate-800"}>
                      {value === undefined ? "—" : value === NO_RESPONSE ? "NR" : value}
                      <span className={isActive ? "text-blue-100" : "text-slate-400"}> /{question.max}</span>
                    </span>
                  </button>
                </li>
              );
            })}
          </ul>

          {/* Number pad for the selected question */}
          <div className="border-t border-slate-200 p-4">
            <div className="mb-3 flex items-center justify-between text-sm">
              <span className="font-semibold text-slate-900">{q.label}</span>
              <span className="text-slate-500">Out of {q.max}</span>
            </div>
            <div className="grid grid-cols-4 gap-2">
              {Array.from({ length: q.max + 1 }, (_, k) => q.max - k).map((n) => (
                <button
                  key={n}
                  type="button"
                  onClick={() => pick(n)}
                  className={`h-10 rounded-lg text-base font-semibold transition ${
                    current === n ? "bg-blue-600 text-white shadow" : "bg-blue-100 text-blue-800 hover:bg-blue-200"
                  }`}
                >
                  {n}
                </button>
              ))}
              <button
                type="button"
                onClick={() => pick(NO_RESPONSE)}
                className={`h-10 rounded-lg text-sm font-semibold transition ${
                  current === NO_RESPONSE ? "bg-slate-700 text-white" : "bg-slate-200 text-slate-700 hover:bg-slate-300"
                }`}
              >
                NR
              </button>
              <button
                type="button"
                onClick={() => pick(null)}
                className="col-span-2 h-10 rounded-lg border border-slate-300 text-sm text-slate-600 hover:bg-slate-50"
              >
                Clear
              </button>
            </div>
            <div className="mt-3 flex justify-between">
              <button
                type="button"
                disabled={active === 0}
                onClick={() => setActive((a) => a - 1)}
                className="rounded-lg border border-slate-300 px-3 py-1.5 text-sm disabled:opacity-40"
              >
                ‹ Prev
              </button>
              <button
                type="button"
                disabled={active === questions.length - 1}
                onClick={() => setActive((a) => a + 1)}
                className="rounded-lg bg-blue-600 px-3 py-1.5 text-sm text-white disabled:opacity-40"
              >
                Next ›
              </button>
            </div>
          </div>

          <div className="border-t border-slate-200 p-4">
            <label className="mb-1 block text-xs font-medium text-slate-600">Feedback</label>
            <textarea
              value={paper.feedback}
              onChange={(e) => update({ feedback: e.target.value })}
              rows={2}
              className={inputClass}
            />
            <div className="mt-3 flex items-center justify-between">
              <span className="text-xs text-green-700">{saved ? "Saved" : ""}</span>
              <button type="button" onClick={save} className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700">
                Save marks
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
