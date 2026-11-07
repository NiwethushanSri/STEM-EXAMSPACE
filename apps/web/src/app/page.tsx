import Link from "next/link";
import { Logo } from "@/components/Logo";
import { subjects, entranceExams } from "@/lib/site-data";
import { SubjectIcon } from "@/components/SubjectIcon";

const whyUs = [
  { icon: "exam" as const, title: "Real exam feel", body: "Mocks follow the same timing and question styles as the real STEM and university entrance papers." },
  { icon: "shield" as const, title: "Written in-house", body: "Our teachers write every paper and test it in class first, so nothing has been seen before." },
  { icon: "clock" as const, title: "Full-length papers", body: "Every mock is a full-length paper, so students practise the whole day, not just a section." },
  { icon: "chart" as const, title: "Detailed results", body: "Each student gets marks by question, weak topics and examiner comments." },
  { icon: "chart" as const, title: "Peer comparison", body: "See how a result compares with the cohort, so progress is measured, not guessed." },
  { icon: "clock" as const, title: "Fast feedback", body: "Online mocks are marked and reported within hours. Physical papers are marked and sent to admin the same week." },
];

const subjectIcons = {
  Maths: "maths",
  "Further Maths": "further-maths",
  Physics: "physics",
  Chemistry: "chemistry",
  Biology: "biology",
  "Computer Science": "computer-science",
} as const;

const subjectTone = [
  "bg-blue-100 text-blue-700",
  "bg-indigo-100 text-indigo-700",
  "bg-sky-100 text-sky-700",
  "bg-emerald-100 text-emerald-700",
  "bg-teal-100 text-teal-700",
  "bg-violet-100 text-violet-700",
];

export default function Home() {
  return (
    <div className="min-h-screen bg-white text-slate-900">
      {/* Utility bar */}
      <div className="bg-slate-900 px-6 py-2 text-xs text-slate-200">
        <div className="mx-auto flex max-w-6xl items-center justify-end gap-6">
          <span>Contact: hello@stemexamspace.co.uk</span>
          <Link href="/login" className="hover:text-white">Sign in</Link>
        </div>
      </div>

      {/* Nav */}
      <header className="sticky top-0 z-10 border-b border-slate-200 bg-white/95 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
          <Link href="/">
            <Logo className="h-16" />
          </Link>
          <nav className="hidden items-center gap-6 text-sm text-slate-700 md:flex">
            <a href="#why-us" className="hover:text-blue-700">Why us</a>
            <a href="#mocks" className="hover:text-blue-700">Mock exams</a>
            <a href="#subjects" className="hover:text-blue-700">Subjects</a>
            <a href="#results" className="hover:text-blue-700">Results</a>
          </nav>
          <Link href="/exams" className="rounded-full bg-blue-600 px-5 py-2 text-sm font-medium text-white shadow-sm hover:bg-blue-700">
            Book a mock
          </Link>
        </div>
      </header>

      {/* Hero */}
      <section className="relative overflow-hidden bg-gradient-to-br from-blue-700 via-blue-600 to-sky-500 text-white">
        <div className="pointer-events-none absolute -right-24 -top-24 h-96 w-96 rounded-full bg-white/10" />
        <div className="pointer-events-none absolute -bottom-32 left-1/3 h-80 w-80 rounded-full bg-white/10" />
        <div className="relative mx-auto grid max-w-6xl gap-12 px-6 py-20 md:grid-cols-2 md:items-center">
          <div>
            <span className="inline-block rounded-full bg-white/15 px-3 py-1 text-xs font-medium tracking-wide">
              Online and in-person mocks
            </span>
            <h1 className="mt-5 text-4xl font-semibold tracking-tight md:text-5xl">
              STEM mock exams that feel like the real thing
            </h1>
            <ul className="mt-6 space-y-3 text-lg text-blue-50">
              <li className="flex items-start gap-3"><span className="mt-2 h-2 w-2 shrink-0 rounded-full bg-amber-300" />Build confidence and exam technique</li>
              <li className="flex items-start gap-3"><span className="mt-2 h-2 w-2 shrink-0 rounded-full bg-amber-300" />Benchmark your ability against the cohort</li>
              <li className="flex items-start gap-3"><span className="mt-2 h-2 w-2 shrink-0 rounded-full bg-amber-300" />Learn from instant results and detailed feedback</li>
            </ul>
            <div className="mt-8 flex flex-wrap gap-3">
              <Link href="/exams" className="rounded-lg bg-white px-6 py-3 font-semibold text-blue-700 shadow-lg hover:bg-blue-50">
                Book now
              </Link>
              <Link href="/exams" className="rounded-lg border border-white/60 px-6 py-3 font-semibold text-white hover:bg-white/10">
                See upcoming exams
              </Link>
            </div>
          </div>

          <div className="relative">
            <img
              src="/images/hero-stem.svg"
              alt="Illustration of an atom, a flask, a bar chart and a marked exam paper"
              className="w-full drop-shadow-2xl"
            />
            {/* Results preview card */}
            <div id="results" className="absolute -bottom-6 -left-2 w-64 rounded-xl bg-white p-5 text-slate-900 shadow-xl md:w-72">
              <div className="text-[11px] uppercase tracking-wide text-slate-500">Sample feedback report</div>
              <div className="mt-1 font-semibold">Physics · Mock 2</div>
              <div className="mt-3 flex items-end gap-5">
                <div>
                  <div className="text-3xl font-semibold text-blue-700">71%</div>
                  <div className="text-[11px] text-slate-500">Your mark</div>
                </div>
                <div>
                  <div className="text-xl font-semibold text-slate-700">62%</div>
                  <div className="text-[11px] text-slate-500">Class average</div>
                </div>
              </div>
              <div className="mt-3 space-y-1.5 text-xs">
                <div className="flex justify-between"><span>Mechanics</span><span className="font-medium">84%</span></div>
                <div className="flex justify-between"><span>Circular motion</span><span className="font-medium text-amber-600">42%</span></div>
                <div className="flex justify-between"><span>Energy transfer</span><span className="font-medium text-amber-600">48%</span></div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Sign-up strip */}
      <section className="bg-slate-900 px-6 py-6 text-white">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 md:flex-row">
          <p className="font-medium">Get an email when the next mock series opens.</p>
          <div className="flex w-full max-w-md gap-2">
            <input
              type="email"
              placeholder="Your email"
              className="w-full rounded bg-white px-3 py-2 text-sm text-slate-900 placeholder:text-slate-500"
            />
            <button className="whitespace-nowrap rounded bg-amber-400 px-4 py-2 text-sm font-semibold text-slate-900 hover:bg-amber-300">
              Notify me
            </button>
          </div>
        </div>
      </section>

      {/* Mock types */}
      <section id="mocks" className="mx-auto max-w-6xl px-6 py-20">
        <p className="text-center text-sm font-medium uppercase tracking-wide text-blue-600">Choose your format</p>
        <h2 className="mt-2 text-center text-3xl font-semibold text-blue-900">Choose your mock</h2>
        <div className="mt-12 grid gap-6 md:grid-cols-2">
          <div className="group overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm transition hover:-translate-y-1 hover:shadow-xl">
            <div className="h-2 bg-gradient-to-r from-blue-600 to-sky-500" />
            <div className="p-8">
              <div className="flex h-14 w-14 items-center justify-center rounded-xl bg-blue-100 text-blue-700">
                <SubjectIcon name="exam" className="h-7 w-7" />
              </div>
              <h3 className="mt-5 text-xl font-semibold">In-person mock exams</h3>
              <ul className="mt-4 space-y-2 text-slate-700">
                <li>• Sit a test in a realistic exam hall</li>
                <li>• Paper answer sheets, scanned for marking</li>
                <li>• Feedback reports after marking</li>
                <li>• Post-exam review led by our teachers</li>
              </ul>
              <Link href="/exams" className="mt-6 inline-block rounded-lg bg-blue-600 px-5 py-2.5 font-medium text-white hover:bg-blue-700">
                Book in-person
              </Link>
            </div>
          </div>
          <div className="group overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm transition hover:-translate-y-1 hover:shadow-xl">
            <div className="h-2 bg-gradient-to-r from-amber-400 to-orange-400" />
            <div className="p-8">
              <div className="flex h-14 w-14 items-center justify-center rounded-xl bg-amber-100 text-amber-700">
                <SubjectIcon name="clock" className="h-7 w-7" />
              </div>
              <h3 className="mt-5 text-xl font-semibold">Online mock exams</h3>
              <ul className="mt-4 space-y-2 text-slate-700">
                <li>• Sit the exam online, the same way as the real test</li>
                <li>• Available immediately, attempt at any time</li>
                <li>• Feedback reports after marking</li>
                <li>• Benchmark against your cohort</li>
              </ul>
              <Link href="/exams" className="mt-6 inline-block rounded-lg bg-blue-600 px-5 py-2.5 font-medium text-white hover:bg-blue-700">
                Book online
              </Link>
            </div>
          </div>
        </div>
      </section>

      {/* Why us */}
      <section id="why-us" className="bg-slate-50 px-6 py-20">
        <div className="mx-auto max-w-6xl">
          <p className="text-center text-sm font-medium uppercase tracking-wide text-blue-600">The difference</p>
          <h2 className="mt-2 text-center text-3xl font-semibold text-blue-900">Why our mocks?</h2>
          <p className="mx-auto mt-3 max-w-2xl text-center text-slate-600">
            Stem Examspace helps students prepare for STEM subjects and university entrance exams with mocks
            that feel like the real thing.
          </p>
          <div className="mt-12 grid gap-6 md:grid-cols-3">
            {whyUs.map((w) => (
              <div key={w.title} className="rounded-2xl bg-white p-6 shadow-sm ring-1 ring-slate-100">
                <div className="flex h-11 w-11 items-center justify-center rounded-lg bg-blue-600 text-white">
                  <SubjectIcon name={w.icon} className="h-5 w-5" />
                </div>
                <h3 className="mt-4 font-semibold text-slate-900">{w.title}</h3>
                <p className="mt-2 text-sm text-slate-600">{w.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Subjects and entrance exams */}
      <section id="subjects" className="mx-auto max-w-6xl px-6 py-20">
        <p className="text-center text-sm font-medium uppercase tracking-wide text-blue-600">Subjects</p>
        <h2 className="mt-2 text-center text-3xl font-semibold text-blue-900">Subjects and entrance exams</h2>
        <div className="mt-12 grid gap-4 sm:grid-cols-2 md:grid-cols-3">
          {subjects.map((s, i) => (
            <Link
              key={s}
              href="/exams"
              className="flex items-center gap-4 rounded-2xl border border-slate-200 bg-white p-5 transition hover:-translate-y-0.5 hover:border-blue-300 hover:shadow-lg"
            >
              <span className={`flex h-12 w-12 shrink-0 items-center justify-center rounded-xl ${subjectTone[i % subjectTone.length]}`}>
                <SubjectIcon name={subjectIcons[s as keyof typeof subjectIcons]} className="h-6 w-6" />
              </span>
              <span className="font-semibold text-slate-900">{s}</span>
            </Link>
          ))}
          {entranceExams.map((e) => (
            <Link
              key={e}
              href="/exams"
              className="flex items-center gap-4 rounded-2xl border border-dashed border-blue-300 bg-blue-50/50 p-5 transition hover:border-blue-500"
            >
              <span className="flex h-12 w-12 shrink-0 items-center justify-center rounded-xl bg-white text-blue-700 shadow-sm">
                <SubjectIcon name="shield" className="h-6 w-6" />
              </span>
              <span>
                <span className="block font-semibold text-slate-900">{e}</span>
                <span className="text-xs text-slate-500">University entrance practice</span>
              </span>
            </Link>
          ))}
        </div>
      </section>

      {/* CTA band */}
      <section className="relative overflow-hidden bg-gradient-to-r from-blue-900 to-blue-700 px-6 py-16 text-center text-white">
        <div className="pointer-events-none absolute -left-16 top-0 h-64 w-64 rounded-full bg-white/10" />
        <div className="relative">
          <h2 className="text-3xl font-semibold">Ready to find out where you stand?</h2>
          <p className="mt-3 text-blue-100">Book a mock and get your first report within days.</p>
          <Link href="/exams" className="mt-7 inline-block rounded-lg bg-amber-400 px-7 py-3 font-semibold text-slate-900 shadow-lg hover:bg-amber-300">
            Book a mock
          </Link>
        </div>
      </section>

      {/* Footer */}
      <footer className="bg-slate-900 px-6 py-10 text-sm text-slate-300">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 md:flex-row">
          <span className="text-base font-semibold text-white">Stem Examspace</span>
          <span>hello@stemexamspace.co.uk</span>
          <span className="text-xs text-slate-400">© 2026 Stem Examspace · stemexamspace.co.uk</span>
        </div>
      </footer>
    </div>
  );
}
