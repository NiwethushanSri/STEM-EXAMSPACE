"use client";

import { useState } from "react";
import { questions, responses } from "@/lib/mock-data";

export default function MarkingPage() {
  const [activeId, setActiveId] = useState(responses[0].id);
  const [marks, setMarks] = useState<Record<string, number | "">>({});
  const [comment, setComment] = useState("");
  const [annotations, setAnnotations] = useState(true);

  const active = responses.find((r) => r.id === activeId) ?? responses[0];
  const totalMax = active.questions.reduce((sum, q) => sum + q.max, 0);
  const totalMarks = active.questions.reduce(
    (sum, q) => sum + (Number(marks[q.id]) || 0),
    0,
  );
  const markedCount = active.questions.filter(
    (q) => marks[q.id] !== undefined && marks[q.id] !== "",
  ).length;

  const setMark = (id: string, max: number, value: string) => {
    if (value === "") {
      setMarks((m) => ({ ...m, [id]: "" }));
      return;
    }
    const n = Math.min(Math.max(Number(value), 0), max);
    setMarks((m) => ({ ...m, [id]: n }));
  };

  return (
    <div className="flex h-screen flex-col bg-white text-slate-900">
      <header className="flex h-14 items-center justify-between bg-blue-700 px-5 text-white">
        <span className="text-lg font-semibold tracking-tight">Stem Examspace</span>
        <nav className="flex gap-5 text-sm">
          <span>Messages</span>
          <span>Menu</span>
          <span>Help</span>
        </nav>
      </header>

      <div className="flex flex-1 min-h-0">
        {/* Worklist */}
        <aside className="w-64 shrink-0 overflow-y-auto border-r border-slate-200 bg-slate-50">
          <div className="border-b border-slate-200 px-4 py-3 text-sm font-semibold text-blue-800">
            Live marking · Physics
          </div>
          <ul>
            {responses.map((r) => (
              <li key={r.id}>
                <button
                  onClick={() => setActiveId(r.id)}
                  className={`w-full px-4 py-3 text-left text-sm hover:bg-blue-50 ${
                    r.id === activeId ? "bg-blue-100 font-medium" : ""
                  }`}
                >
                  <div className="text-blue-700 underline">{r.id}</div>
                  <div className="text-xs text-slate-500">
                    {r.status === "not_started" ? "Marking not started" : "In progress"}
                  </div>
                </button>
              </li>
            ))}
          </ul>
        </aside>

        {/* Response viewer */}
        <main className="flex min-w-0 flex-1 flex-col bg-slate-100">
          <div className="flex items-center justify-between border-b border-slate-200 bg-white px-4 py-2 text-sm">
            <span>
              Response <span className="font-semibold">{active.id}</span>
            </span>
            <span className="text-slate-500">1 of {responses.length} in worklist</span>
          </div>
          <div className="flex-1 overflow-y-auto p-6">
            <div className="mx-auto max-w-2xl rounded bg-white p-8 shadow-sm">
              <p className="mb-4 text-xs uppercase tracking-wide text-slate-400">
                Scanned response
              </p>
              <p className="text-slate-500">
                The scanned answer script for response {active.id} appears here. Upload
                integration comes with the database step.
              </p>
            </div>
          </div>
        </main>

        {/* Mark panel */}
        <aside className="flex w-80 shrink-0 flex-col border-l border-slate-200 bg-white">
          <div className="flex items-center justify-between border-b border-slate-200 px-4 py-3">
            <span className="text-sm font-medium">Mark by candidate</span>
            <label className="flex items-center gap-2 text-sm">
              Annotations
              <button
                onClick={() => setAnnotations((v) => !v)}
                className={`relative h-5 w-9 rounded-full transition ${
                  annotations ? "bg-blue-600" : "bg-slate-300"
                }`}
                aria-pressed={annotations}
              >
                <span
                  className={`absolute top-0.5 h-4 w-4 rounded-full bg-white transition ${
                    annotations ? "left-4.5" : "left-0.5"
                  }`}
                />
              </button>
            </label>
          </div>

          <ul className="flex-1 overflow-y-auto">
            {active.questions.map((q) => (
              <li
                key={q.id}
                className="flex items-center justify-between border-b border-slate-100 px-4 py-2.5 text-sm"
              >
                <span>Q{q.label}</span>
                <span className="flex items-center gap-1">
                  <input
                    type="number"
                    min={0}
                    max={q.max}
                    value={marks[q.id] ?? ""}
                    onChange={(e) => setMark(q.id, q.max, e.target.value)}
                    className="w-14 rounded border border-slate-300 px-2 py-1 text-right focus:border-blue-600 focus:outline-none"
                    aria-label={`Mark for question ${q.label}`}
                  />
                  <span className="text-slate-500">/ {q.max}</span>
                </span>
              </li>
            ))}
          </ul>

          <div className="border-t border-slate-200 p-4">
            <label className="mb-1 block text-xs font-medium text-slate-600">
              Examiner comment
            </label>
            <textarea
              value={comment}
              onChange={(e) => setComment(e.target.value)}
              rows={3}
              className="w-full rounded border border-slate-300 p-2 text-sm focus:border-blue-600 focus:outline-none"
            />
          </div>

          <div className="flex items-center justify-between border-t border-slate-200 px-4 py-3">
            <div>
              <div className="text-xs text-slate-500">
                Marked {markedCount} of {questions.length}
              </div>
              <div className="text-lg font-semibold text-blue-700">
                {totalMarks} / {totalMax}
              </div>
            </div>
            <button
              disabled={markedCount < active.questions.length}
              className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-slate-300"
            >
              Submit
            </button>
          </div>
        </aside>
      </div>
    </div>
  );
}
