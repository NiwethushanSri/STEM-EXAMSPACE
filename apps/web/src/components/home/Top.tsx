import type { ReactNode } from "react";
import Image from "next/image";
import Link from "next/link";
import { countdownText, londonDate, paperState, pickNextPaper, type PublicExam } from "@/lib/home-exams";
import { ArrowIcon, DoodleBook, DoodleMarks, DoodleSit, ParentIcon, Ring, StudentIcon, TutorIcon } from "./Icons";
import s from "./home.module.css";

/** One word of a heading, circled by hand in blue. `after` (such as a comma) stays on the word's line, outside the ring. */
export function Ringed({ children, after }: { children: ReactNode; after?: string }) {
  const ringed = (
    <span className={s.ringed}>
      {children}
      <Ring className={s.ring} />
    </span>
  );
  if (!after) return ringed;
  return (
    <span className={s.nowrap}>
      {ringed}
      {after}
    </span>
  );
}

/** Where "Book a seat" goes: straight to the next bookable paper, else the timetable. */
export function bookHrefFor(exams: PublicExam[], now: Date): string {
  const next = pickNextPaper(exams, now);
  if (!next) return "/exams";
  const state = paperState(next, now);
  return state === "open" || state === "few" ? `/exams/${next.id}/book` : "/exams";
}

export function Header({ signedIn, bookHref }: { signedIn: boolean; bookHref: string }) {
  return (
    <header className={s.header}>
      <div className={s.headerInner}>
        <Link href="/" className={s.logo}>
          <Image src="/images/stem-examspace-logo.png" alt="Stem Examspace home" width={1062} height={369} priority />
        </Link>
        <nav aria-label="Main" className={s.navLinks}>
          <a href="#papers">Timetable</a>
          <a href="#analysis">Analysis</a>
          <a href="#how">How it works</a>
        </nav>
        {signedIn ? (
          <Link href="/account/bookings" className={s.signIn}>
            My bookings
          </Link>
        ) : (
          <Link href="/login" className={s.signIn}>
            Sign in
          </Link>
        )}
        <Link href={bookHref} className={s.btn}>
          Book a seat
        </Link>
      </div>
      <nav aria-label="Sections" className={s.subnav}>
        <a href="#papers">Timetable</a>
        <a href="#analysis">Analysis</a>
        <a href="#how">How it works</a>
        <a href="#faq">Questions</a>
      </nav>
    </header>
  );
}

const ROLES = [
  {
    href: "/register",
    title: "Parents",
    sub: "Book papers and follow your child’s progress",
    tone: s.toneMaths,
    icon: <ParentIcon />,
  },
  {
    href: "/login",
    title: "Students",
    sub: "Your bookings, index card and results",
    tone: s.toneOther,
    icon: <StudentIcon />,
  },
  {
    href: "/login",
    title: "Tutors",
    sub: "Follow your students’ bookings",
    tone: s.toneComputing,
    icon: <TutorIcon />,
  },
];

/** `next` is undefined while the timetable is still loading; `days` counts UK calendar days to it. */
export function Hero({ next, days, bookHref }: { next: PublicExam | null | undefined; days?: number; bookHref: string }) {
  const when = next ? londonDate(next.starts_at) : null;
  const countdown = days === undefined ? "" : ` · ${countdownText(days).toLowerCase()}`;
  const badge =
    next === undefined
      ? "Checking the timetable…"
      : next && when
        ? `Next paper: ${next.title}, ${when.short}${countdown}`
        : "Next mock series: dates coming soon";
  return (
    <section className={s.hero} aria-labelledby="hero-title">
      <div className={`${s.container} ${s.heroGrid}`}>
        <div>
          <span className={s.badge}>
            <span className={`${s.badgeDot} ${next ? "" : s.badgeDotWait}`} aria-hidden="true" />
            {badge}
          </span>
          <h1 id="hero-title" className={s.h1}>
            Know exactly where your child stands before the real exams
          </h1>
          <p className={s.heroText}>
            Full GCSE and A level mock papers, sat under exam conditions and marked question by question. Every result builds a detailed analysis
            of strengths, gaps and progress over time.
          </p>
          <div className={s.heroActions}>
            <Link href={bookHref} className={s.btn}>
              Book a seat
            </Link>
            <a href="#analysis" className={s.textLink}>
              See the analysis <ArrowIcon />
            </a>
          </div>
        </div>
        <nav aria-label="Start here" className={s.roles}>
          {ROLES.map((r) => (
            <Link key={r.title} href={r.href} className={s.role}>
              <span className={`${s.roleIcon} ${r.tone}`}>{r.icon}</span>
              <span>
                <span className={s.roleTitle}>{r.title}</span>
                <span className={s.roleSub}>{r.sub}</span>
              </span>
              <ArrowIcon className={s.roleArrow} />
            </Link>
          ))}
        </nav>
      </div>
    </section>
  );
}

const STEPS = [
  {
    doodle: <DoodleBook className={s.doodle} />,
    title: "Book a seat",
    sub: "Online, paper by paper",
    body: (
      <>
        Choose a paper from the timetable and book online. <span className={s.highlight}>Seats left and prices</span> are shown before you
        book.
      </>
    ),
  },
  {
    doodle: <DoodleSit className={s.doodle} />,
    title: "Sit the paper",
    sub: "Under exam conditions",
    body: (
      <>
        Students bring their <strong>index card</strong>, sit at an individual desk and work to the clock,{" "}
        <span className={s.highlight}>exactly as in the summer exams</span>.
      </>
    ),
  },
  {
    doodle: <DoodleMarks className={s.doodle} />,
    title: "Results and analysis",
    sub: "Marked question by question",
    body: (
      <>
        Scripts are marked <strong>anonymously</strong> against the mark scheme. Results arrive with{" "}
        <span className={s.highlight}>a full analysis by question and topic</span>.
      </>
    ),
  },
];

export function HowItWorks() {
  return (
    <section id="how" className={`${s.section} ${s.soft}`} aria-labelledby="how-title">
      <div className={s.container}>
        <h2 id="how-title" className={`${s.h2} ${s.center}`}>
          How it <Ringed>works</Ringed>
        </h2>
        <ol className={s.steps}>
          {STEPS.map((step, i) => (
            <li key={step.title} className={s.stepCard}>
              {step.doodle}
              <div className={s.stepHead}>
                <span className={s.stepNo} aria-hidden="true">
                  {i + 1}
                </span>
                <div>
                  <h3 className={s.stepTitle}>{step.title}</h3>
                  <p className={s.stepSub}>{step.sub}</p>
                </div>
              </div>
              <p className={s.stepBody}>{step.body}</p>
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
}
