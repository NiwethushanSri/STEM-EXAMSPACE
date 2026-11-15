"use client";

import { useState } from "react";
import { linearForecast } from "@stem/shared";
import s from "./home.module.css";

type Subject = {
  name: string;
  points: { label: string; mark: number; cohort: number }[];
  topics: [string, number][];
};

/** One example A level student's results across four subjects (illustration only). */
const SUBJECTS: Subject[] = [
  {
    name: "Maths",
    points: [
      { label: "Jun", mark: 66, cohort: 64 },
      { label: "Jul", mark: 72, cohort: 66 },
      { label: "Sep", mark: 78, cohort: 67 },
      { label: "Oct", mark: 84, cohort: 68 },
    ],
    topics: [
      ["Calculus", 88],
      ["Mechanics", 86],
      ["Trigonometry", 81],
      ["Statistics", 79],
      ["Integration by parts", 54],
    ],
  },
  {
    name: "Physics",
    points: [
      { label: "Jun", mark: 52, cohort: 54 },
      { label: "Jul", mark: 55, cohort: 56 },
      { label: "Sep", mark: 61, cohort: 60 },
      { label: "Oct", mark: 71, cohort: 62 },
    ],
    topics: [
      ["Mechanics", 84],
      ["Electricity", 77],
      ["Waves", 69],
      ["Energy transfer", 48],
      ["Circular motion", 42],
    ],
  },
  {
    name: "Chemistry",
    points: [
      { label: "Jun", mark: 49, cohort: 60 },
      { label: "Jul", mark: 54, cohort: 61 },
      { label: "Sep", mark: 57, cohort: 62 },
      { label: "Oct", mark: 58, cohort: 65 },
    ],
    topics: [
      ["Acids and bases", 71],
      ["Equilibria", 66],
      ["Organic chemistry", 52],
      ["Isomerism", 41],
      ["Reaction mechanisms", 38],
    ],
  },
  {
    name: "Biology",
    points: [
      { label: "Jun", mark: 70, cohort: 63 },
      { label: "Jul", mark: 74, cohort: 64 },
      { label: "Sep", mark: 77, cohort: 64 },
    ],
    topics: [
      ["Cells", 85],
      ["Ecology", 80],
      ["Genetics", 72],
      ["Respiration", 66],
      ["Photosynthesis", 58],
    ],
  },
];

function tone(v: number): string {
  if (v >= 70) return s.topicStrong;
  if (v >= 55) return s.topicMid;
  return s.topicWeak;
}

function Chart({ subject, cohort }: { subject: Subject; cohort: boolean }) {
  const marks = subject.points.map((p) => p.mark);
  const avg = subject.points.map((p) => p.cohort);
  const { values: ahead } = linearForecast(marks, 1);
  const labels = [...subject.points.map((p) => p.label), "Next"];
  const W = 520;
  const H = 250;
  const L = 54;
  const R = 22;
  const T = 24;
  const B = 34;
  const lo = 30;
  const x = (i: number) => L + (i * (W - L - R)) / (labels.length - 1);
  const y = (v: number) => T + ((100 - v) * (H - T - B)) / (100 - lo);
  const line = (vals: number[]) => vals.map((v, i) => `${i ? "L" : "M"}${x(i)} ${y(v)}`).join(" ");
  const last = marks.length - 1;
  const future = `M${x(last)} ${y(marks[last])} L${x(last + 1)} ${y(ahead[0])}`;
  const label = `${subject.name}: marks ${marks.join(", ")} per cent${cohort ? `; cohort average ${avg.join(", ")} per cent` : ""}; forecast for the next mock ${ahead[0]} per cent.`;

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className={s.dashChart} role="img" aria-label={label}>
      {[40, 60, 80, 100].map((g) => (
        <g key={g}>
          <line x1={L} x2={W - R} y1={y(g)} y2={y(g)} stroke="#e3e6ec" strokeWidth="1" />
          <text x={L - 8} y={y(g) + 4} textAnchor="end" fontSize="11" fill="#5a6382">
            {g}%
          </text>
        </g>
      ))}
      {cohort ? <path d={line(avg)} fill="none" stroke="#5a6382" strokeWidth="2" strokeDasharray="2 5" strokeLinecap="round" /> : null}
      <path d={line(marks)} fill="none" stroke="#1f64ae" strokeWidth="3" strokeLinejoin="round" strokeLinecap="round" />
      <path d={future} fill="none" stroke="#ee9330" strokeWidth="3" strokeDasharray="6 6" strokeLinecap="round" />
      {marks.map((m, i) => (
        <g key={`m${i}`}>
          <circle cx={x(i)} cy={y(m)} r="5.5" fill="#1f64ae" stroke="#ffffff" strokeWidth="2" />
          <text x={x(i)} y={y(m) - 12} textAnchor="middle" fontSize="12" fontWeight="700" fill="#10224f">
            {m}%
          </text>
        </g>
      ))}
      <circle cx={x(last + 1)} cy={y(ahead[0])} r="5.5" fill="#ffffff" stroke="#ee9330" strokeWidth="3" />
      <text x={x(last + 1)} y={y(ahead[0]) - 12} textAnchor="middle" fontSize="12" fontWeight="700" fill="#8a4a0b">
        {ahead[0]}%
      </text>
      {labels.map((lab, i) => (
        <text key={lab} x={x(i)} y={H - 10} textAnchor="middle" fontSize="11" fill="#5a6382">
          {lab}
        </text>
      ))}
    </svg>
  );
}

/** A working example of the student analysis: switch subjects, compare with the cohort. */
export function AnalysisDemo() {
  const [index, setIndex] = useState(1);
  const [cohort, setCohort] = useState(true);
  const subject = SUBJECTS[index];
  const marks = subject.points.map((p) => p.mark);
  const latest = marks[marks.length - 1];
  const change = latest - marks[marks.length - 2];
  const avg = subject.points[subject.points.length - 1].cohort;
  const { values: ahead } = linearForecast(marks, 1);
  const focus = [...subject.topics].sort((a, b) => a[1] - b[1]).filter(([, v]) => v < 60).slice(0, 2);

  return (
    <div className={s.dash}>
      <div className={s.dashTop}>
        <div role="tablist" aria-label="Subject" className={s.dashTabs}>
          {SUBJECTS.map((sub, i) => {
            const last = sub.points[sub.points.length - 1].mark;
            return (
              <button
                key={sub.name}
                type="button"
                role="tab"
                id={`subject-${i}`}
                aria-selected={i === index}
                aria-controls="analysis-panel"
                onClick={() => setIndex(i)}
              >
                {sub.name}
                <span>{last}%</span>
              </button>
            );
          })}
        </div>
        <span className={s.dashWho}>Example student · Year 13</span>
      </div>

      <div role="tabpanel" id="analysis-panel" aria-labelledby={`subject-${index}`} className={s.dashBody}>
        <dl className={s.kpis}>
          <div>
            <dt>Latest mock</dt>
            <dd>{latest}%</dd>
          </div>
          <div>
            <dt>Since last mock</dt>
            <dd className={change >= 0 ? s.up : s.down}>
              {change >= 0 ? "+" : "−"}
              {Math.abs(change)} pts
            </dd>
          </div>
          <div>
            <dt>Cohort average</dt>
            <dd>{avg}%</dd>
          </div>
          <div>
            <dt>Forecast, next mock</dt>
            <dd className={s.fore}>{ahead[0]}%</dd>
          </div>
        </dl>

        <div className={s.dashGrid}>
          <div className={s.dashCard}>
            <div className={s.dashCardHead}>
              <b>Progress over time</b>
              <label className={s.switch}>
                <input type="checkbox" checked={cohort} onChange={(e) => setCohort(e.target.checked)} />
                <span className={s.switchTrack} aria-hidden="true" />
                Compare with cohort
              </label>
            </div>
            <Chart subject={subject} cohort={cohort} />
            <div className={s.dashLegend} aria-hidden="true">
              <span>
                <i className={s.lgMarks} />
                Marks
              </span>
              {cohort ? (
                <span>
                  <i className={s.lgCohort} />
                  Cohort average
                </span>
              ) : null}
              <span>
                <i className={s.lgFore} />
                Forecast
              </span>
            </div>
          </div>

          <div className={s.dashCard}>
            <div className={s.dashCardHead}>
              <b>By topic</b>
              <span className={s.dashHint}>Latest mock</span>
            </div>
            <ul className={s.topics}>
              {subject.topics.map(([t, v]) => (
                <li key={t}>
                  <span className={s.topicName}>{t}</span>
                  <span className={s.topicTrack} aria-hidden="true">
                    <span className={`${s.topicFill} ${tone(v)}`} style={{ width: `${v}%` }} />
                  </span>
                  <span className={s.topicValue}>{v}%</span>
                </li>
              ))}
            </ul>
            <div className={s.focus}>
              <b>Focus next</b>
              {focus.length ? focus.map(([t]) => t).join(" and ") : "No topic below 60%. Keep practising full papers."}
            </div>
          </div>
        </div>
      </div>
      <p className={s.dashNote}>Example data. Forecasts are estimates from the mocks so far, not guarantees.</p>
    </div>
  );
}
