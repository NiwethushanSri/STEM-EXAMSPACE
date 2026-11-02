import { Logo } from "@/components/Logo";
import { relationOf, average } from "@/lib/results";
import type { Child, TestResult } from "@/lib/site-data";

// Grade bands for mock marks out of 100. These are placeholders until the school confirms its scale.
export function gradeFor(mark: number): string {
  if (mark >= 70) return "A";
  if (mark >= 60) return "B";
  if (mark >= 50) return "C";
  if (mark >= 40) return "D";
  if (mark >= 30) return "E";
  return "F";
}

// Short subject code printed on the sheet, e.g. "PHY" for Physics.
function codeFor(r: TestResult): string {
  return r.subject.slice(0, 3).toUpperCase();
}

// Prints only the sheet: the site header and navigation are left out of the page.
const PRINT_CSS = `
@page { size: A4; margin: 12mm; }
@media print {
  body * { visibility: hidden; }
  #result-sheet, #result-sheet * { visibility: visible; }
  #result-sheet { position: absolute; left: 0; top: 0; width: 100%; max-width: none; padding: 0; box-shadow: none; }
}
`;

// A printable result sheet, laid out like a university result sheet.
export function ResultSheetPaper({ child }: { child: Child }) {
  const relation = relationOf(child);
  const results = child.results;
  const hasResults = results.length > 0;
  const totalMarks = results.reduce((s, r) => s + r.mark, 0);
  const passed = results.filter((r) => r.mark >= 40).length;
  const overall = average(child);
  const weak = Array.from(new Set(results.flatMap((r) => r.weakAreas)));

  return (
    <div id="result-sheet" className="mx-auto w-full max-w-[794px] bg-white px-10 py-10 text-slate-900 shadow-sm print:shadow-none">
      <style>{PRINT_CSS}</style>

      {/* Letterhead. The logo box is a placeholder until the logo is uploaded. */}
      <header className="flex flex-col items-center text-center">
        <Logo className="h-20" />
        <p className="mt-3 text-sm text-slate-600">Mock examination centre</p>
        <h2 className="mt-5 text-base font-semibold uppercase tracking-[0.25em] text-slate-800">Student&apos;s result sheet</h2>
      </header>

      <div className="mt-6 border-t border-slate-200 pt-5">
        {/* Student details */}
        <dl className="grid grid-cols-2 gap-x-10 gap-y-3 text-sm">
          <Detail label="Student ID" value={child.indexNumber} />
          <Detail label="Level" value={child.grade} />
          <Detail label="Full name" value={child.name} />
          <Detail label="Series" value="Mock series 2026" />
          <Detail label={`${relation} of`} value={child.parent} />
          <Detail label="Session" value="2026" />
        </dl>
      </div>

      {hasResults ? (
        <>
          {/* Results per subject */}
          <table className="mt-6 w-full border border-slate-300 text-left text-sm">
            <thead className="bg-blue-900 text-xs uppercase tracking-wide text-white">
              <tr>
                <th className="px-2 py-2 font-medium">#</th>
                <th className="px-2 py-2 font-medium">Code</th>
                <th className="px-2 py-2 font-medium">Subject</th>
                <th className="px-2 py-2 font-medium">Test</th>
                <th className="px-2 py-2 text-right font-medium">Mark</th>
                <th className="px-2 py-2 text-right font-medium">Class avg</th>
                <th className="px-2 py-2 text-center font-medium">Grade</th>
                <th className="px-2 py-2 text-center font-medium">Status</th>
              </tr>
            </thead>
            <tbody>
              {results.map((r, i) => (
                <tr key={`${r.subject}-${r.test}`} className={`border-t border-slate-200 ${i % 2 ? "bg-slate-50" : ""}`}>
                  <td className="px-2 py-2 text-slate-500">{i + 1}</td>
                  <td className="px-2 py-2 font-mono text-xs">{codeFor(r)}</td>
                  <td className="px-2 py-2 font-medium">{r.subject}</td>
                  <td className="px-2 py-2 text-slate-600">{r.test}</td>
                  <td className="px-2 py-2 text-right font-semibold">{r.mark}</td>
                  <td className="px-2 py-2 text-right text-slate-600">{r.classAverage}</td>
                  <td className="px-2 py-2 text-center font-semibold">{gradeFor(r.mark)}</td>
                  <td className={`px-2 py-2 text-center text-xs font-semibold ${r.mark >= 40 ? "text-green-700" : "text-red-700"}`}>
                    {r.mark >= 40 ? "PASS" : "FAIL"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>

          {/* Summary */}
          <table className="mt-4 w-full border border-slate-300 text-left text-sm">
            <thead className="bg-slate-100 text-xs uppercase tracking-wide text-slate-600">
              <tr>
                <th className="px-2 py-2 font-medium">Summary</th>
                <th className="px-2 py-2 text-right font-medium">Tests</th>
                <th className="px-2 py-2 text-right font-medium">Total marks</th>
                <th className="px-2 py-2 text-right font-medium">Average</th>
                <th className="px-2 py-2 text-right font-medium">Passed</th>
                <th className="px-2 py-2 text-center font-medium">Overall grade</th>
              </tr>
            </thead>
            <tbody>
              <tr className="border-t border-slate-200">
                <td className="px-2 py-2 font-medium">Current series</td>
                <td className="px-2 py-2 text-right">{results.length}</td>
                <td className="px-2 py-2 text-right">{totalMarks} / {results.length * 100}</td>
                <td className="px-2 py-2 text-right font-semibold">{overall}%</td>
                <td className="px-2 py-2 text-right">{passed} of {results.length}</td>
                <td className="px-2 py-2 text-center text-lg font-bold text-blue-900">{gradeFor(overall)}</td>
              </tr>
            </tbody>
          </table>

          {/* Remarks */}
          <div className="mt-4 rounded border border-slate-300 p-4 text-sm">
            <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Remarks</div>
            {weak.length > 0 ? (
              <>
                <p className="mt-1 text-slate-700">Topics to revise before the next mock:</p>
                <p className="mt-1 font-medium">{weak.join(", ")}</p>
              </>
            ) : (
              <p className="mt-1 text-slate-700">No weak topics recorded this series. Keep it up.</p>
            )}
          </div>
        </>
      ) : (
        <p className="mt-10 text-center text-sm text-slate-500">No results have been recorded for this student yet.</p>
      )}

      {/* Footer */}
      <footer className="mt-10 border-t border-slate-200 pt-4 text-xs text-slate-500">
        <div className="flex items-end justify-between gap-6">
          <div className="w-1/2">
            <div className="h-8 border-b border-slate-400" />
            <div className="mt-1">Examiner or exams officer</div>
          </div>
          <div className="w-1/2">
            <div className="h-8 border-b border-slate-400" />
            <div className="mt-1">Date issued</div>
          </div>
        </div>
        <p className="mt-4 text-center font-semibold text-amber-700">
          This is not a transcript. Results are subject to moderation and approval.
        </p>
        <p className="mt-1 text-center">Contact your Stem Examspace coordinator first for any enquiries.</p>
      </footer>
    </div>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex gap-3">
      <dt className="w-28 shrink-0 text-xs font-semibold uppercase tracking-wide text-slate-500">{label}</dt>
      <dd className="font-semibold text-slate-900">{value}</dd>
    </div>
  );
}
