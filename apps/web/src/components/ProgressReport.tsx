"use client";

import { useEffect, useMemo, useState } from "react";
import { Badge, Card, Stat, Table } from "@/components/AppShell";
import { TrendChart } from "@/components/Charts";
import { gradeFor } from "@/components/ResultSheetPaper";
import { DEMO_CHILD_ID, hasReportSent, sendReportToParent } from "@/lib/alerts";
import { ReportCard } from "@/components/ReportCard";
import { buildTracker, feedbackFor, inTerm, inTermRows, schoolYearOf, termLabel } from "@stem/shared";
import { attendance, student, subjectTeachers, testHistory } from "@/lib/site-data";

// Prints only the report: the site header and navigation are left out of the page.
const PRINT_CSS = `
@page { size: A4; margin: 12mm; }
@media print {
  body * { visibility: hidden; }
  #report-card, #report-card * { visibility: visible; }
  #report-card { position: absolute; left: 0; top: 0; width: 100%; }
}
`;

const tracker = buildTracker(testHistory);
const allTerms = [...tracker.actualTerms, ...tracker.predictedTerms];

function pct(v: number | null | undefined): string {
  return v === null || v === undefined ? "—" : `${v}%`;
}

function signed(v: number): string {
  return `${v > 0 ? "+" : ""}${v}`;
}

// Student and parent progress report: term tracker, marks, attendance and next-year prediction.
export function ProgressReport({ audience }: { audience: "student" | "parent" }) {
  const latest = termLabel(tracker.actualTerms[tracker.actualTerms.length - 1]);
  const [selected, setSelected] = useState(latest);
  const [sent, setSent] = useState(false);

  useEffect(() => {
    setSent(hasReportSent(DEMO_CHILD_ID, selected));
  }, [selected]);

  const term = allTerms.find((t) => termLabel(t) === selected) ?? tracker.actualTerms[tracker.actualTerms.length - 1];
  const label = termLabel(term);
  const isPredicted = tracker.predictedTerms.some((t) => termLabel(t) === label);
  const predictedIndex = tracker.predictedTerms.findIndex((t) => termLabel(t) === label);

  const termTests = testHistory.filter((t) => inTerm(t.date, term));
  const sessions = inTermRows(attendance, term);
  const present = sessions.filter((a) => a.status === "Present").length;
  const termAverage = termTests.length ? Math.round(termTests.reduce((s, t) => s + t.mark, 0) / termTests.length) : 0;
  const passed = termTests.filter((t) => t.mark >= 40).length;
  const weak = Array.from(new Set(termTests.flatMap((t) => t.weakAreas)));

  // Report card rows and notes, built from the same term data as the rest of the page.
  const cardRows = tracker.subjects.flatMap((s) => {
    const marks = termTests.filter((t) => t.subject === s);
    if (marks.length === 0) return [];
    const avg = Math.round(marks.reduce((sum, t) => sum + t.mark, 0) / marks.length);
    const subjectWeak = Array.from(new Set(marks.flatMap((t) => t.weakAreas)));
    return [
      {
        subject: s,
        grade: gradeFor(avg),
        teacher: subjectTeachers[s] ?? "To be assigned",
        feedback: feedbackFor(avg, subjectWeak),
      },
    ];
  });
  const cardNotes = [
    `Overall average ${termAverage}% (grade ${gradeFor(termAverage)}). ${passed} of ${termTests.length} tests passed.`,
    `Attended ${present} of ${sessions.length} sessions this term.`,
    weak.length ? `Topics to revise before the next mock: ${weak.join(", ")}.` : "No weak topics recorded this term.",
    `Predicted ${termLabel(tracker.predictedTerms[0])} average: ${tracker.overallForecast[0]}% (estimate).`,
  ];

  const latestOverall = tracker.overall[tracker.overall.length - 1];
  const previousOverall = tracker.overall[tracker.overall.length - 2];

  function sendToParent() {
    const body = `${student.name}'s ${label} report: average ${termAverage}%, ${passed} of ${termTests.length} tests passed, ${present} of ${sessions.length} sessions attended. Open the parent portal for the full report.`;
    sendReportToParent(DEMO_CHILD_ID, label, body);
    setSent(true);
  }

  return (
    <div id="progress-report" className="space-y-6">
      <style>{PRINT_CSS}</style>

      {/* Student details and actions */}
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h2 className="text-lg font-semibold text-slate-900">{student.name}</h2>
          <p className="text-sm text-slate-500">
            Index {student.indexNumber} · {student.grade} · {student.school}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-3 print:hidden">
          <button
            type="button"
            onClick={() => window.print()}
            disabled={isPredicted}
            title={isPredicted ? "Report cards are available once a term has results" : "Prints the report card"}
            className="rounded-lg border border-blue-600 px-4 py-2 text-sm font-medium text-blue-700 hover:bg-blue-50 disabled:cursor-not-allowed disabled:opacity-40 disabled:hover:bg-transparent"
          >
            Download PDF
          </button>
          {audience === "student" &&
            (sent ? (
              <span className="rounded-full bg-green-100 px-2.5 py-1 text-xs font-medium text-green-800">
                Sent to parent
              </span>
            ) : isPredicted ? (
              <span className="text-xs text-slate-500">Reports are sent for terms with results.</span>
            ) : (
              <button
                type="button"
                onClick={sendToParent}
                className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
              >
                Send to parent
              </button>
            ))}
        </div>
      </div>

      {/* Term selector */}
      <div className="flex flex-wrap gap-2 print:hidden">
        {allTerms.map((t) => {
          const key = termLabel(t);
          const predicted = tracker.predictedTerms.some((p) => termLabel(p) === key);
          return (
            <button
              key={key}
              onClick={() => setSelected(key)}
              className={`rounded-full px-4 py-1.5 text-sm font-medium transition ${
                key === label
                  ? "bg-blue-600 text-white shadow"
                  : "border border-slate-300 bg-white text-slate-700 hover:border-blue-400"
              }`}
            >
              {key}
              {predicted ? " · predicted" : ""}
            </button>
          );
        })}
      </div>

      {/* Report card for the selected term. Download PDF prints only this card. */}
      {!isPredicted && (
        <div className="overflow-x-auto">
          <ReportCard
            studentName={student.name}
            indexNumber={student.indexNumber}
            grade={student.grade}
            school={student.school}
            termName={term.name}
            schoolYear={schoolYearOf(term)}
            parentName={student.parent}
            rows={cardRows}
            notes={cardNotes}
          />
        </div>
      )}

      <div className="grid gap-4 md:grid-cols-4">
        <Stat label="Latest term average" value={`${latestOverall}%`} />
        <Stat
          label="Change since last term"
          value={previousOverall === undefined ? "—" : signed(latestOverall - previousOverall)}
        />
        <Stat label={`Predicted ${termLabel(tracker.predictedTerms[0])}`} value={`${tracker.overallForecast[0]}%`} />
        <Stat label="Tests sat" value={testHistory.length} />
      </div>

      {/* Tracker across the year */}
      <Card title="Term tracker and prediction">
        <Table
          head={[
            "Subject",
            ...tracker.actualTerms.map(termLabel),
            ...tracker.predictedTerms.map((t) => `${termLabel(t)} (predicted)`),
            "Change per term",
          ]}
          rows={[
            ...tracker.subjects.map((s) => [
              <span key={`${s}-n`} className="font-medium">{s}</span>,
              ...tracker.actual[s].map((v, i) => <span key={`${s}-a-${i}`}>{pct(v)}</span>),
              ...tracker.predictedTerms.map((_, k) => (
                <span key={`${s}-p-${k}`} className="font-semibold text-amber-700">
                  {pct(tracker.forecast[s][k])}
                </span>
              )),
              <span key={`${s}-s`} className={tracker.slope[s] >= 0 ? "text-green-700" : "text-red-700"}>
                {signed(tracker.slope[s])}
              </span>,
            ]),
            [
              <span key="overall" className="font-bold">Overall</span>,
              ...tracker.overall.map((v, i) => <span key={`o-${i}`} className="font-bold">{v}%</span>),
              ...tracker.overallForecast.map((v, k) => (
                <span key={`o-p-${k}`} className="font-bold text-amber-700">{v}%</span>
              )),
              <span key="overall-slope" className="font-bold">{signed(tracker.overallSlope)}</span>,
            ],
          ]}
        />
        <p className="mt-4 text-xs text-slate-500">
          Terms: Autumn runs September to December, Spring runs January to early April, and Summer runs from the second
          week of April to the third week of July. Predictions use a straight-line trend through the average mark of each
          term, so they are an estimate from {tracker.actualTerms.length} terms and will change as more results come in.
        </p>
      </Card>

      {/* Chart of the whole year */}
      <Card title="Progress over the year, actual and predicted">
        <TrendChart
          labels={tracker.actualTerms.map(termLabel)}
          actual={tracker.overall}
          forecast={tracker.overallForecast}
          forecastLabels={tracker.predictedTerms.map(termLabel)}
        />
        <div className="mt-3 flex flex-wrap gap-4 text-xs text-slate-500">
          <span className="flex items-center gap-1.5"><span className="h-0.5 w-6 bg-blue-600" />Actual term average</span>
          <span className="flex items-center gap-1.5">
            <span className="h-0.5 w-6 border-t-2 border-dashed border-amber-500" />Predicted
          </span>
        </div>
      </Card>

      {/* The selected term in detail */}
      {isPredicted ? (
        <Card title={`${label} · predicted marks`}>
          <p className="mb-4 text-sm text-slate-600">
            This term has not happened yet. These are predicted marks based on the trend so far, not results.
          </p>
          <Table
            head={["Subject", "Predicted mark", "Last term", "Change per term", "Confidence"]}
            rows={tracker.subjects.map((s) => {
              const lastKnown = [...tracker.actual[s]].reverse().find((v) => v !== null) ?? null;
              return [
                s,
                <span key={`${s}-f`} className="font-semibold text-amber-700">{pct(tracker.forecast[s][predictedIndex])}</span>,
                pct(lastKnown),
                signed(tracker.slope[s]),
                tracker.actual[s].filter((v) => v !== null).length < 3 ? "Low, two terms of results" : "Medium",
              ];
            })}
          />
        </Card>
      ) : (
        <Card title={`${label} · report`}>
          <div className="mb-4 grid gap-4 text-sm md:grid-cols-4">
            <div><span className="text-slate-500">Tests sat</span><div className="font-semibold">{termTests.length}</div></div>
            <div><span className="text-slate-500">Average</span><div className="font-semibold">{termAverage}% · grade {gradeFor(termAverage)}</div></div>
            <div><span className="text-slate-500">Tests passed</span><div className="font-semibold">{passed} of {termTests.length}</div></div>
            <div>
              <span className="text-slate-500">Attendance</span>
              <div className="font-semibold">{present} of {sessions.length} sessions</div>
            </div>
          </div>

          <Table
            head={["Subject", "Test", "Date", "Mark", "Class avg", "High", "Low", "Grade", "Status"]}
            rows={termTests.map((t) => [
              <span key={`${t.subject}-${t.test}-s`} className="font-medium">{t.subject}</span>,
              t.test,
              t.date,
              <span key={`${t.subject}-${t.test}-m`} className="font-semibold">{t.mark}%</span>,
              `${t.classAverage}%`,
              `${t.highest}%`,
              `${t.lowest}%`,
              gradeFor(t.mark),
              <Badge key={`${t.subject}-${t.test}-b`} tone={t.mark >= 40 ? "green" : "red"}>
                {t.mark >= 40 ? "Pass" : "Fail"}
              </Badge>,
            ])}
          />

          <div className="mt-6">
            <h3 className="mb-2 text-sm font-semibold text-blue-800">Topics to revise</h3>
            {weak.length === 0 ? (
              <p className="text-sm text-slate-500">No weak topics recorded this term.</p>
            ) : (
              <ul className="list-disc space-y-1 pl-5 text-sm">
                {weak.map((w) => (
                  <li key={w}>{w}</li>
                ))}
              </ul>
            )}
          </div>
        </Card>
      )}
    </div>
  );
}
