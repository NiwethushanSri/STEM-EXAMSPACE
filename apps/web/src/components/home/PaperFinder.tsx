"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { SubjectIcon } from "@/components/SubjectIcon";
import { STATE_LABEL, subjectGroup, type Level, type PaperCardData } from "@/lib/home-exams";
import { ArrowIcon } from "./Icons";
import { PILL, SUBJECTS, TONE, iconFor } from "./subject-ui";
import s from "./home.module.css";

const LEVELS: ("All" | Level)[] = ["All", "GCSE", "A level"];
const SHOWN = 9;

function PaperCard({ c }: { c: PaperCardData }) {
  const bookable = c.state === "open" || c.state === "few";
  return (
    <li className={s.paper}>
      <div className={s.paperTop}>
        <span className={`${s.paperIcon} ${TONE[c.group]}`}>
          <SubjectIcon name={iconFor(c.subject)} />
        </span>
        <div>
          <h3 className={s.paperTitle}>{c.title}</h3>
          <p className={s.paperSub}>{c.paper || c.subject}</p>
        </div>
      </div>
      <dl className={s.facts}>
        <dt>Date</dt>
        <dd>{c.date}</dd>
        <dt>Time</dt>
        <dd>{c.time}</dd>
        <dt>Where</dt>
        <dd>{c.place}</dd>
      </dl>
      <div className={s.paperDivider} />
      <div className={s.paperFoot}>
        <span className={s.price}>{c.price}</span>
        <div className={s.paperFootRight}>
          <span className={`${s.pill} ${PILL[c.state]}`}>
            {bookable ? (c.seatLine ?? STATE_LABEL.open) : STATE_LABEL[c.state]}
          </span>
          {bookable ? (
            <Link href={`/exams/${c.id}/book`} className={s.btn} aria-label={`Book a seat for ${c.title}${c.paper ? `, ${c.paper}` : ""}`}>
              Book
            </Link>
          ) : null}
        </div>
      </div>
    </li>
  );
}

/** Filter the live papers by qualification, subject and seats, on the page. */
export function PaperFinder({ cards }: { cards: PaperCardData[] }) {
  const [level, setLevel] = useState<"All" | Level>("All");
  const [subject, setSubject] = useState<string | null>(null);
  const [seatsOnly, setSeatsOnly] = useState(false);

  const subjects = useMemo(() => {
    const counts = new Map<string, number>();
    for (const c of cards) counts.set(c.subject, (counts.get(c.subject) ?? 0) + 1);
    const order = (n: string) => {
      const i = (SUBJECTS as readonly string[]).indexOf(n);
      return i === -1 ? 99 : i;
    };
    return [...counts.entries()].sort((a, b) => order(a[0]) - order(b[0]) || a[0].localeCompare(b[0]));
  }, [cards]);

  const matching = cards.filter(
    (c) =>
      (level === "All" || c.level === level) &&
      (subject === null || c.subject === subject) &&
      (!seatsOnly || c.state === "open" || c.state === "few"),
  );
  const shown = matching.slice(0, SHOWN);
  const filtered = level !== "All" || subject !== null || seatsOnly;

  function reset() {
    setLevel("All");
    setSubject(null);
    setSeatsOnly(false);
  }

  return (
    <div className={s.finder}>
      <div className={s.finderBar}>
        <div role="group" aria-label="Qualification" className={s.segment}>
          {LEVELS.map((l) => (
            <button key={l} type="button" aria-pressed={level === l} onClick={() => setLevel(l)}>
              {l === "All" ? "All levels" : l}
            </button>
          ))}
        </div>
        <label className={s.switch}>
          <input type="checkbox" checked={seatsOnly} onChange={(e) => setSeatsOnly(e.target.checked)} />
          <span className={s.switchTrack} aria-hidden="true" />
          Only papers with seats
        </label>
      </div>

      <div role="group" aria-label="Subject" className={s.chips}>
        <button type="button" className={s.chip} aria-pressed={subject === null} onClick={() => setSubject(null)}>
          All subjects <span className={s.chipCount}>{cards.length}</span>
        </button>
        {subjects.map(([name, count]) => (
          <button key={name} type="button" className={s.chip} aria-pressed={subject === name} onClick={() => setSubject(subject === name ? null : name)}>
            <span className={`${s.chipIcon} ${TONE[subjectGroup(name)]}`}>
              <SubjectIcon name={iconFor(name)} />
            </span>
            {name} <span className={s.chipCount}>{count}</span>
          </button>
        ))}
      </div>

      <p className={s.finderCount} aria-live="polite">
        {matching.length === cards.length
          ? `${cards.length} upcoming paper${cards.length === 1 ? "" : "s"}`
          : `${matching.length} of ${cards.length} papers match`}
      </p>

      {shown.length > 0 ? (
        <ul className={s.papers}>
          {shown.map((c) => (
            <PaperCard key={c.id} c={c} />
          ))}
        </ul>
      ) : (
        <div className={s.empty}>
          <p className={s.emptyTitle}>No papers match</p>
          <p>Try another subject or level, or see every paper.</p>
          <button type="button" className={s.btn} onClick={reset}>
            Show all papers
          </button>
        </div>
      )}

      <div className={s.moreRow}>
        <Link href="/exams" className={s.textLink}>
          {matching.length > SHOWN ? `See all ${matching.length} on the timetable` : "See the full timetable"} <ArrowIcon />
        </Link>
        {filtered && shown.length > 0 ? (
          <button type="button" className={s.linkButton} onClick={reset}>
            Clear filters
          </button>
        ) : null}
      </div>
    </div>
  );
}
