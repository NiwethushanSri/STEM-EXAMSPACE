"use client";

import { useState } from "react";
import { markHistory, results } from "@/lib/site-data";
import { linearForecast } from "@/lib/forecast";
import { TrendChart, ComparisonBars } from "@/components/Charts";
import { Card, Stat } from "@/components/AppShell";

const subjects = Object.keys(markHistory);

export function AnalysisView() {
  const [subject, setSubject] = useState(subjects[0]);

  const history = markHistory[subject];
  const marks = history.map((h) => h.mark);
  const labels = history.map((h) => h.label);
  const { values: forecast, slope } = linearForecast(marks, 2);

  const latest = marks[marks.length - 1];
  const best = Math.max(...marks);
  const direction = slope > 0 ? "improving" : slope < 0 ? "dropping" : "steady";

  const comparison = results.map((r) => ({
    subject: r.subject,
    mark: r.mark,
    classAverage: r.classAverage,
  }));

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap gap-2">
        {subjects.map((s) => (
          <button
            key={s}
            onClick={() => setSubject(s)}
            className={`rounded-full px-4 py-1.5 text-sm font-medium transition ${
              s === subject
                ? "bg-blue-600 text-white shadow"
                : "border border-slate-300 bg-white text-slate-700 hover:border-blue-400"
            }`}
          >
            {s}
          </button>
        ))}
      </div>

      <div className="grid gap-4 md:grid-cols-4">
        <Stat label="Latest mark" value={`${latest}%`} />
        <Stat label="Best mark" value={`${best}%`} />
        <Stat label="Trend" value={`${slope > 0 ? "+" : ""}${slope} per test`} />
        <Stat label="Forecast next test" value={`${forecast[0]}%`} />
      </div>

      <Card title={`${subject} · mark history and forecast`}>
        <TrendChart
          labels={labels}
          actual={marks}
          forecast={forecast}
          forecastLabels={forecast.map((_, k) => `Next ${k + 1}`)}
        />
        <div className="mt-3 flex flex-wrap gap-4 text-xs text-slate-500">
          <span className="flex items-center gap-1.5"><span className="h-0.5 w-6 bg-blue-600" />Your marks</span>
          <span className="flex items-center gap-1.5">
            <span className="h-0.5 w-6 border-t-2 border-dashed border-amber-500" />Forecast
          </span>
        </div>
        <p className="mt-4 text-sm text-slate-600">
          Your marks are <span className="font-medium">{direction}</span> in {subject}. If the trend
          continues, your next test would be about <span className="font-semibold">{forecast[0]}%</span>.
          Forecasts use the last few tests only, so treat them as an estimate.
        </p>
      </Card>

      <Card title="You compared with the class average">
        <ComparisonBars rows={comparison} />
      </Card>
    </div>
  );
}
