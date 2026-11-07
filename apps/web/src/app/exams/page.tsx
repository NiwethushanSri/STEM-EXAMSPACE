import Link from "next/link";
import { subjects, entranceExams, upcomingExams } from "@/lib/site-data";

export default function ExamCatalogue() {
  return (
    <div className="min-h-screen bg-slate-50 text-slate-900">
      <header className="flex items-center justify-between bg-blue-700 px-6 py-4 text-white">
        <Link href="/" className="text-lg font-semibold tracking-tight">Stem Examspace</Link>
        <Link href="/login" className="text-sm hover:underline">Sign in</Link>
      </header>
      <main className="mx-auto max-w-5xl px-6 py-10">
        <h1 className="text-2xl font-semibold">Exams</h1>
        <p className="mt-1 text-sm text-slate-600">Online and face-to-face mock exams.</p>

        <h2 className="mb-3 mt-8 font-semibold">Subjects</h2>
        <div className="grid gap-3 md:grid-cols-3">
          {subjects.map((s) => (
            <div key={s} className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
              <div className="font-medium text-blue-800">{s}</div>
              <div className="mt-1 text-xs text-slate-500">Online or physical mock</div>
            </div>
          ))}
        </div>

        <h2 className="mb-3 mt-8 font-semibold">University entrance practice</h2>
        <div className="grid gap-3 md:grid-cols-3">
          {entranceExams.map((e) => (
            <div key={e} className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
              <div className="font-medium text-blue-800">{e}</div>
              <div className="mt-1 text-xs text-slate-500">Practice paper</div>
            </div>
          ))}
        </div>

        <h2 className="mb-3 mt-8 font-semibold">Upcoming</h2>
        <ul className="divide-y divide-slate-200 rounded-lg border border-slate-200 bg-white text-sm">
          {upcomingExams.map((e) => (
            <li key={e.subject} className="flex justify-between px-4 py-3">
              <span>{e.subject} · {e.date} {e.time}</span>
              <span className="text-slate-500">{e.type}</span>
            </li>
          ))}
        </ul>
      </main>
    </div>
  );
}
