import Link from "next/link";
import { SubjectIcon } from "@/components/SubjectIcon";
import { subjectGroup, toCardData, upcoming, type PublicExam } from "@/lib/home-exams";
import { PaperFinder } from "./PaperFinder";
import { Ringed } from "./Top";
import { SUBJECTS, TONE, iconFor } from "./subject-ui";
import s from "./home.module.css";

function Heading() {
  return (
    <>
      <h2 id="papers-title" className={`${s.h2} ${s.center}`}>
        Upcoming mock <Ringed>papers</Ringed>
      </h2>
      <p className={`${s.lede} ${s.center}`}>Every published GCSE and A level mock, with seats remaining and prices. All times are UK time.</p>
    </>
  );
}

/** The subjects we run, as plain links, for when no paper is published yet. */
function SubjectLinks() {
  return (
    <nav aria-label="Subjects" className={s.chips}>
      {SUBJECTS.map((name) => (
        <Link key={name} href={`/exams?subject=${encodeURIComponent(name)}`} className={s.chip}>
          <span className={`${s.chipIcon} ${TONE[subjectGroup(name)]}`}>
            <SubjectIcon name={iconFor(name)} />
          </span>
          {name}
        </Link>
      ))}
    </nav>
  );
}

/** The upcoming papers, live from the timetable, with filters on the page. */
export function Papers({ exams, now, error }: { exams: PublicExam[]; now: Date; error: boolean }) {
  const cards = upcoming(exams, now).map((e) => toCardData(e, now));

  return (
    <section id="papers" className={s.section} aria-labelledby="papers-title">
      <div className={s.container}>
        <Heading />
        {error ? (
          <div className={s.empty} role="alert">
            <p className={s.emptyTitle}>The timetable could not be loaded</p>
            <p>Please refresh the page, or open the full timetable.</p>
            <Link href="/exams" className={s.btn}>
              Open the timetable
            </Link>
          </div>
        ) : cards.length === 0 ? (
          <>
            <SubjectLinks />
            <div className={s.empty}>
              <p className={s.emptyTitle}>No papers are published yet</p>
              <p>The next mock series is being set. Register now and you can book the moment the dates go up.</p>
              <Link href="/register" className={s.btn}>
                Register a student
              </Link>
            </div>
          </>
        ) : (
          <PaperFinder cards={cards} />
        )}
      </div>
    </section>
  );
}

/** While the timetable loads. */
export function PapersFallback() {
  return (
    <section id="papers" className={s.section} aria-labelledby="papers-title">
      <div className={s.container}>
        <Heading />
        <p className={`${s.finderCount} ${s.center}`}>Loading the timetable…</p>
      </div>
    </section>
  );
}
