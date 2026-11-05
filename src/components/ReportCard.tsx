import { Logo } from "@/components/Logo";

export type ReportCardRow = { subject: string; grade: string; teacher: string; feedback: string };

// A printable report card in the layout of a school report: letterhead, student details,
// a subject table with grade, teacher and feedback, notes, and a parent's signature.
export function ReportCard({
  id = "report-card",
  studentName,
  indexNumber,
  grade,
  school,
  termName,
  schoolYear,
  parentName,
  rows,
  notes,
}: {
  id?: string;
  studentName: string;
  indexNumber: string;
  grade: string;
  school: string;
  termName: string;
  schoolYear: string;
  parentName: string;
  rows: ReportCardRow[];
  notes: string[];
}) {
  return (
    <div
      id={id}
      className="mx-auto w-full min-w-[720px] max-w-[794px] bg-white px-8 py-8 text-slate-900 shadow-sm ring-1 ring-slate-200 print:min-w-0 print:shadow-none print:ring-0"
    >
      {/* Letterhead */}
      <header className="flex flex-col items-center gap-1 text-center">
        <Logo className="h-14" />
        <p className="text-sm text-slate-600">Mock examination centre · hello@stemexamspace.co.uk</p>
      </header>

      <h2 className="mt-6 text-center text-3xl font-bold uppercase tracking-wide text-blue-700">Progress report card</h2>
      <p className="text-center text-sm font-semibold uppercase tracking-[0.2em] text-slate-500">Student report</p>

      {/* Student details */}
      <dl className="mt-6 grid grid-cols-2 gap-x-10 gap-y-2 border-t border-slate-200 pt-5 text-sm">
        <Detail label="Student" value={studentName} />
        <Detail label="Term" value={termName} />
        <Detail label="Grade" value={grade} />
        <Detail label="School year" value={schoolYear} />
        <Detail label="Index number" value={indexNumber} />
        <Detail label="School" value={school} />
      </dl>

      {/* Subjects */}
      <table className="mt-6 w-full border border-slate-200 text-left text-sm">
        <thead className="bg-blue-700 text-xs uppercase tracking-wide text-white">
          <tr>
            <th className="w-32 px-3 py-2 font-medium">Subject</th>
            <th className="w-16 px-3 py-2 text-center font-medium">Grade</th>
            <th className="w-36 px-3 py-2 font-medium">Teacher</th>
            <th className="px-3 py-2 font-medium">Feedback</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={r.subject} className={`border-t border-slate-200 align-top ${i % 2 ? "bg-slate-50" : ""}`}>
              <td className="px-3 py-2.5 font-semibold">{r.subject}</td>
              <td className="px-3 py-2.5 text-center font-semibold">{r.grade}</td>
              <td className="px-3 py-2.5">{r.teacher}</td>
              <td className="px-3 py-2.5 leading-relaxed">{r.feedback}</td>
            </tr>
          ))}
        </tbody>
      </table>

      {/* Notes and signature */}
      <div className="mt-5 grid grid-cols-3 gap-4 text-sm">
        <section className="col-span-2 rounded border border-slate-200">
          <h3 className="border-b border-slate-200 py-1.5 text-center text-sm font-semibold text-blue-700">Additional notes</h3>
          <ul className="list-disc space-y-1.5 p-4 pl-8 leading-relaxed">
            {notes.map((n) => (
              <li key={n}>{n}</li>
            ))}
          </ul>
        </section>
        <section className="rounded border border-slate-200">
          <h3 className="border-b border-slate-200 py-1.5 text-center text-sm font-semibold text-blue-700">Parent&apos;s signature</h3>
          <div className="flex h-full flex-col justify-end px-4 pb-3 pt-10 text-center">
            <div className="border-b border-slate-400" />
            <div className="mt-1 text-xs text-slate-600">{parentName}</div>
          </div>
        </section>
      </div>

      {/* Footer */}
      <footer className="mt-6 flex items-center gap-4 border-t border-slate-200 pt-3 text-xs text-slate-500">
        <span>hello@stemexamspace.co.uk</span>
        <span className="ml-auto h-2 w-40 rounded bg-blue-700" />
      </footer>
    </div>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex gap-3">
      <dt className="w-28 shrink-0 text-xs font-semibold uppercase tracking-wide text-slate-500">{label}</dt>
      <dd className="font-medium text-slate-900">{value}</dd>
    </div>
  );
}
