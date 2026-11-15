import type { ReactNode } from "react";
import { linearForecast } from "@stem/shared";
import { SubjectIcon } from "@/components/SubjectIcon";
import s from "./home.module.css";

/** One example student's Physics mocks; the last is 12 / 16. */
const HISTORY = [52, 58, 63, 75];

const QUESTIONS = [
  { q: "Question 1", got: 3, of: 3 },
  { q: "Question 2", got: 4, of: 5 },
  { q: "Question 3", got: 2, of: 4 },
  { q: "4 (a)", got: 2, of: 2 },
  { q: "4 (b)", got: 1, of: 2 },
];

/** The same student's booked papers (the dates match the example timetable). */
const BOOKED = [
  { subject: "GCSE Maths", icon: "maths", tone: s.toneMaths, paper: "Paper 1 Higher", when: "Sat 5 June · 09:00", where: "Hall A" },
  { subject: "GCSE Physics", icon: "physics", tone: s.toneScience, paper: "Paper 1 Higher", when: "Sat 12 June · 09:00", where: "Hall A" },
  { subject: "GCSE Chemistry", icon: "chemistry", tone: s.toneScience, paper: "Paper 2 Higher", when: "Sun 13 June · 09:00", where: "Hall B" },
  { subject: "GCSE Biology", icon: "biology", tone: s.toneScience, paper: "Paper 1 Higher", when: "Sat 19 June · 09:00", where: "Hall A" },
] as const;

/** Mock history per subject; Physics is the result in the centre phone. */
const PROGRESS = [
  { subject: "Maths", icon: "maths", tone: s.toneMaths, marks: [66, 72, 78, 84] },
  { subject: "Physics", icon: "physics", tone: s.toneScience, marks: HISTORY },
  { subject: "Chemistry", icon: "chemistry", tone: s.toneScience, marks: [49, 54, 57, 58] },
  { subject: "Biology", icon: "biology", tone: s.toneScience, marks: [70, 74, 77] },
] as const;

function ScoreRing({ pct }: { pct: number }) {
  const r = 34;
  const c = 2 * Math.PI * r;
  return (
    <svg viewBox="0 0 84 84" className={s.ring84} aria-hidden="true">
      <circle cx="42" cy="42" r={r} fill="none" stroke="#e3f4f3" strokeWidth="8" />
      <circle
        cx="42"
        cy="42"
        r={r}
        fill="none"
        stroke="#2c9a97"
        strokeWidth="8"
        strokeLinecap="round"
        strokeDasharray={`${(pct / 100) * c} ${c}`}
        transform="rotate(-90 42 42)"
      />
      <text x="42" y="48" textAnchor="middle" fontSize="19" fontWeight="800" fill="#10224f">
        {pct}%
      </text>
    </svg>
  );
}

function Sparkline({ marks, ahead }: { marks: readonly number[]; ahead: number[] }) {
  const all = [...marks, ...ahead];
  const W = 240;
  const H = 56;
  const lo = 40;
  const x = (i: number) => 8 + (i * (W - 16)) / (all.length - 1);
  const y = (v: number) => 8 + ((100 - v) * (H - 16)) / (100 - lo);
  const last = marks.length - 1;
  const done = marks.map((m, i) => `${i ? "L" : "M"}${x(i)} ${y(m)}`).join(" ");
  const future = `M${x(last)} ${y(marks[last])} ` + ahead.map((v, k) => `L${x(last + k + 1)} ${y(v)}`).join(" ");
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className={s.spark} aria-hidden="true">
      <path d={done} fill="none" stroke="#1f64ae" strokeWidth="2.5" strokeLinejoin="round" strokeLinecap="round" />
      <path d={future} fill="none" stroke="#ee9330" strokeWidth="2.5" strokeDasharray="5 5" strokeLinecap="round" />
      {marks.map((m, i) => (
        <circle key={i} cx={x(i)} cy={y(m)} r="3.5" fill="#1f64ae" />
      ))}
      {ahead.map((v, k) => (
        <circle key={`f${k}`} cx={x(last + k + 1)} cy={y(v)} r="3.5" fill="#ffffff" stroke="#ee9330" strokeWidth="2" />
      ))}
    </svg>
  );
}

/** The phone's status bar: time, signal, Wi-Fi and battery. */
function StatusBar() {
  return (
    <div className={s.statusBar} aria-hidden="true">
      <span>9:41</span>
      <span className={s.statusIcons}>
        <svg viewBox="0 0 18 12" width="18" height="12">
          <rect x="0" y="8" width="3" height="4" rx="1" fill="currentColor" />
          <rect x="5" y="5.5" width="3" height="6.5" rx="1" fill="currentColor" />
          <rect x="10" y="3" width="3" height="9" rx="1" fill="currentColor" />
          <rect x="15" y="0" width="3" height="12" rx="1" fill="currentColor" />
        </svg>
        <svg viewBox="0 0 16 12" width="16" height="12">
          <path d="M8 11.2l2.3-2.6a3.3 3.3 0 0 0-4.6 0z" fill="currentColor" />
          <path d="M3.9 6.6a5.8 5.8 0 0 1 8.2 0l1.4-1.6a7.9 7.9 0 0 0-11 0z" fill="currentColor" />
          <path d="M1.2 3.6a9.7 9.7 0 0 1 13.6 0L16 2.2A11.6 11.6 0 0 0 0 2.2z" fill="currentColor" />
        </svg>
        <svg viewBox="0 0 27 12" width="27" height="12">
          <rect x="0.5" y="0.5" width="22" height="11" rx="3.2" fill="none" stroke="currentColor" opacity="0.4" />
          <rect x="2" y="2" width="16" height="8" rx="2" fill="currentColor" />
          <path d="M24 4v4a2 2 0 0 0 0-4z" fill="currentColor" opacity="0.45" />
        </svg>
      </span>
    </div>
  );
}

type Tab = "Exams" | "Results" | "Progress" | "Card";

const TABS: { label: Tab; d: string }[] = [
  { label: "Exams", d: "M5 5h14v15H5zM5 9h14M9 3v4M15 3v4" },
  { label: "Results", d: "M5 19V11M10 19V6M15 19v-5M20 19V9" },
  { label: "Progress", d: "M4 17l5-5 4 4 7-8M15 8h5v5" },
  { label: "Card", d: "M4 6h16v12H4zM8 10h4M8 14h6M16 10h1" },
];

/** A current flagship phone running the app, open on the given tab. */
function Phone({ tab, label, className, children }: { tab: Tab; label: string; className: string; children: ReactNode }) {
  return (
    <div className={`${s.phone} ${className}`} role="img" aria-label={label}>
      <span className={`${s.hw} ${s.hwAction}`} />
      <span className={`${s.hw} ${s.hwVolUp}`} />
      <span className={`${s.hw} ${s.hwVolDown}`} />
      <span className={`${s.hw} ${s.hwPower}`} />
      <div className={s.phoneScreen}>
        <span className={s.island} />
        <StatusBar />
        <div className={s.appContent}>{children}</div>
        <nav className={s.tabBar} aria-hidden="true">
          {TABS.map((t) => (
            <span key={t.label} className={t.label === tab ? s.tabOn : undefined}>
              <svg viewBox="0 0 24 24">
                <path d={t.d} fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
              {t.label}
            </span>
          ))}
        </nav>
        <span className={s.homeBar} />
      </div>
    </div>
  );
}

function ExamsScreen() {
  const [next, ...rest] = BOOKED;
  return (
    <>
      <h3 className={`${s.largeTitle} ${s.largeTitleTop}`}>Exams</h3>
      <div className={s.appCard}>
        <span className={s.appKicker}>Next paper</span>
        <div className={s.appCardHead}>
          <span className={`${s.paperIcon} ${next.tone}`}>
            <SubjectIcon name={next.icon} />
          </span>
          <div>
            <b>{next.subject}</b>
            <span>{next.paper}</span>
          </div>
        </div>
        <dl className={s.nextFacts}>
          <div>
            <dt>When</dt>
            <dd>{next.when}</dd>
          </div>
          <div>
            <dt>Where</dt>
            <dd>{next.where}</dd>
          </div>
        </dl>
        <span className={`${s.pill} ${s.pillOpen}`}>Booked and paid</span>
      </div>
      <span className={s.appSection}>Also booked</span>
      <ul className={s.appList}>
        {rest.map((b) => (
          <li key={b.subject}>
            <span className={`${s.paperIcon} ${b.tone}`}>
              <SubjectIcon name={b.icon} />
            </span>
            <div>
              <b>{b.subject}</b>
              <span>{b.when}</span>
            </div>
          </li>
        ))}
      </ul>
    </>
  );
}

function ResultScreen({ got, max, pct, ahead }: { got: number; max: number; pct: number; ahead: number[] }) {
  return (
    <>
      <div className={s.appNav}>
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
        Results
      </div>
      <h3 className={s.largeTitle}>Physics</h3>

      <div className={s.appCard}>
        <div className={s.appCardHead}>
          <span className={`${s.paperIcon} ${s.toneScience}`}>
            <SubjectIcon name="physics" />
          </span>
          <div>
            <b>GCSE Physics</b>
            <span>Paper 1 · Mock 4</span>
          </div>
        </div>
        <div className={s.scoreRow}>
          <ScoreRing pct={pct} />
          <div>
            <b className={s.scoreMarks}>
              {got} / {max} marks
            </b>
            <span className={`${s.pill} ${s.pillOpen}`}>Up 12% on Mock 3</span>
          </div>
        </div>
        <ol className={s.appBars}>
          {QUESTIONS.map((q) => (
            <li key={q.q}>
              <span>{q.q}</span>
              <span className={s.barTrack}>
                <span className={s.barFill} style={{ width: `${(q.got / q.of) * 100}%` }} data-full={q.got === q.of ? "true" : undefined} />
              </span>
              <span>
                {q.got}/{q.of}
              </span>
            </li>
          ))}
        </ol>
      </div>

      <div className={s.appNote}>
        <b>Marker’s note · 4 (b)</b>
        Right method, but give the units: 2.5 m/s².
      </div>

      <div className={s.appCard}>
        <div className={s.forecastHead}>
          <b>Forecast</b>
          <span>
            Next mock <b>{ahead[0]}%</b>
          </span>
        </div>
        <Sparkline marks={HISTORY} ahead={ahead} />
      </div>
    </>
  );
}

function ProgressScreen() {
  const rows = PROGRESS.map((p) => {
    const latest = p.marks[p.marks.length - 1];
    const change = latest - p.marks[p.marks.length - 2];
    return { ...p, latest, change, next: linearForecast([...p.marks], 1).values[0] };
  });
  const average = Math.round(rows.reduce((n, r) => n + r.latest, 0) / rows.length);
  return (
    <>
      <h3 className={`${s.largeTitle} ${s.largeTitleTop}`}>Progress</h3>
      <div className={s.appCard}>
        <span className={s.appKicker}>All subjects</span>
        <b className={s.bigStat}>{average}%</b>
        <span className={s.statNote}>Average of the latest mocks</span>
      </div>
      <span className={s.appSection}>By subject</span>
      <ul className={s.appList}>
        {rows.map((r) => (
          <li key={r.subject}>
            <span className={`${s.paperIcon} ${r.tone}`}>
              <SubjectIcon name={r.icon} />
            </span>
            <div>
              <b>{r.subject}</b>
              <span>
                Forecast <em>{r.next}%</em>
              </span>
            </div>
            <span className={s.progressNow}>
              {r.latest}%<small>{r.change >= 0 ? `+${r.change}` : r.change}</small>
            </span>
          </li>
        ))}
      </ul>
    </>
  );
}

/**
 * Three screens of the Stem Examspace app on current phones: the booked exams, the newest result and
 * progress across subjects. Example data, drawn in code.
 */
export function PhoneResult() {
  const got = QUESTIONS.reduce((n, q) => n + q.got, 0);
  const max = QUESTIONS.reduce((n, q) => n + q.of, 0);
  const pct = Math.round((got / max) * 100);
  const { values: ahead } = linearForecast(HISTORY, 1);

  return (
    <figure className={s.phoneFigure}>
      <div className={s.phoneTrio}>
        <Phone
          tab="Exams"
          className={`${s.phoneSide} ${s.phoneLeft}`}
          label="Example exams screen in the app: the next booked paper, GCSE Maths Paper 1 on Saturday 5 June at 09:00 in Hall A, and three more booked papers."
        >
          <ExamsScreen />
        </Phone>
        <Phone
          tab="Progress"
          className={`${s.phoneSide} ${s.phoneRight}`}
          label="Example progress screen in the app: the latest mark and the forecast for Maths, Physics, Chemistry and Biology."
        >
          <ProgressScreen />
        </Phone>
        <Phone
          tab="Results"
          className={s.phoneCentre}
          label={`Example result in the app: GCSE Physics Paper 1, ${got} out of ${max} (${pct} per cent), with marks for each question, the marker's note and a forecast of ${ahead[0]} per cent for the next mock.`}
        >
          <ResultScreen got={got} max={max} pct={pct} ahead={ahead} />
        </Phone>
      </div>
      <figcaption className={s.caption}>Example screens from the Stem Examspace app</figcaption>
    </figure>
  );
}
