import Image from "next/image";
import Link from "next/link";
import { ParentIcon, StudentIcon, TeacherIcon, TickIcon } from "./Icons";
import { Ringed } from "./Top";
import s from "./home.module.css";

const PARENTS = [
  "Book papers online and manage every booking in one account.",
  "See the date, hall, time and price of each paper before booking.",
  "Follow results and the analysis by topic after every mock.",
  "Cancel unpaid bookings, or request a cancellation once paid.",
];

const TEACHERS = [
  "See the upcoming papers in your subjects, with seats booked.",
  "Run exam day from the register: check students in by QR code or index number.",
  "Mark scripts on screen, question by question, with a pen.",
];

const STUDENTS = [
  "An index number and card, as in public examinations.",
  "An individual desk in an exam hall, timed exactly like the real paper.",
  "Anonymous marking, judged on the answers alone.",
  "Results, marker’s notes and forecasts in the app.",
];

function Checks({ items }: { items: string[] }) {
  return (
    <ul className={s.checks}>
      {items.map((t) => (
        <li key={t}>
          <span className={s.checkDot}>
            <TickIcon />
          </span>
          <span style={{ color: "var(--text)" }}>{t}</span>
        </li>
      ))}
    </ul>
  );
}

const GROUPS = [
  { title: "For students", tone: s.toneOther, icon: <StudentIcon />, items: STUDENTS },
  { title: "For parents", tone: s.toneMaths, icon: <ParentIcon />, items: PARENTS },
  { title: "For teachers", tone: s.toneComputing, icon: <TeacherIcon />, items: TEACHERS },
];

/** Students sit the paper, parents decide and pay, teachers run the day and mark. */
export function Families() {
  return (
    <section id="one-place" className={`${s.section} ${s.soft}`} aria-labelledby="who-title">
      <div className={s.container}>
        <h2 id="who-title" className={`${s.h2} ${s.center}`}>
          One <Ringed>place</Ringed> for students, parents and teachers
        </h2>
        <div className={`${s.duo} ${s.trio}`}>
          {GROUPS.map((g) => (
            <div key={g.title} className={s.duoCard}>
              <div className={s.duoHead}>
                <span className={`${s.roleIcon} ${g.tone}`}>{g.icon}</span>
                <h3 className={s.duoTitle}>{g.title}</h3>
              </div>
              <Checks items={g.items} />
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

export function Closing({ bookHref }: { bookHref: string }) {
  return (
    <section className={`${s.section} ${s.soft}`} aria-labelledby="close-title">
      <div className={`${s.container} ${s.center}`}>
        <h2 id="close-title" className={s.h2}>
          Book the next <Ringed>mock</Ringed>
        </h2>
        <p className={s.lede}>A full paper under exam conditions, with analysis that shows exactly what to work on before the summer.</p>
        <div className={s.closingActions}>
          <Link href={bookHref} className={s.btn}>
            Book a seat
          </Link>
          <Link href="/register" className={`${s.btn} ${s.btnGhost}`}>
            Create a family account
          </Link>
        </div>
      </div>
    </section>
  );
}

export function Footer() {
  return (
    <footer className={s.footer}>
      <div className={s.container}>
        <div className={s.footerGrid}>
          <div className={s.footerBrand}>
            <Link href="/" className={s.footerLogo}>
              <Image src="/images/stem-examspace-logo.png" alt="Stem Examspace home" width={1062} height={369} />
            </Link>
          </div>
          <nav aria-labelledby="f-exams" className={s.footerCol}>
            <h2 id="f-exams">Mock exams</h2>
            <ul>
              <li>
                <Link href="/exams">Timetable</Link>
              </li>
              <li>
                <a href="#how">How it works</a>
              </li>
              <li>
                <a href="#analysis">Analysis</a>
              </li>
              <li>
                <a href="#exam-day">Index card</a>
              </li>
            </ul>
          </nav>
          <nav aria-labelledby="f-account" className={s.footerCol}>
            <h2 id="f-account">Your account</h2>
            <ul>
              <li>
                <Link href="/login">Sign in</Link>
              </li>
              <li>
                <Link href="/register">Create an account</Link>
              </li>
              <li>
                <Link href="/account/bookings">My bookings</Link>
              </li>
            </ul>
          </nav>
          <div className={s.footerCol}>
            <h2>Contact</h2>
            <ul>
              <li>
                <a href="mailto:hello@stemexamspace.co.uk">hello@stemexamspace.co.uk</a>
              </li>
            </ul>
          </div>
        </div>
        <p className={s.footerNote}>© 2026 Stem Examspace. All times on this site are UK time.</p>
      </div>
    </footer>
  );
}
