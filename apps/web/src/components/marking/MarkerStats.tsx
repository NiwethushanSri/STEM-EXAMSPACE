import { agreementText, differenceText, percentText, secondsText, statsNote, type ExamStats } from "@/lib/marking-stats";

const HEAD = [
  "Marker",
  "Scripts marked",
  "Average mark",
  "Agreement with the second marker",
  "With seeded scripts",
  "With practice",
  "Usual time per script",
  "Sent back",
];

/** The mean gap between the first and second markers' totals of the pieces compared. */
const gapText = (gap: number) => `Totals ${Math.round(gap * 10) / 10} ${gap === 1 ? "mark" : "marks"} apart on average`;

/** An exam's marker statistics (marking_stats): above the table, what the figures are for; then the exam's scripts
 * marked, average mark and usual time; then one row per marker: scripts marked, average mark beside the other markers'
 * of the same questions, agreement with the second marker, with seeded scripts and with practice, usual time per script
 * and scripts sent back, and under the row any note, headed "Worth a look". Markers' names only; nothing of a
 * candidate. */
export function MarkerStats({ stats }: { stats: ExamStats }) {
  const { exam, markers } = stats;
  return (
    <div className="space-y-4">
      <p className="rounded border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">
        These figures are a prompt to look, not a finding. Nothing here changes a mark or a marker&apos;s standing by itself.
      </p>
      <p className="text-sm text-slate-700">
        {exam.pieces} {exam.pieces === 1 ? "script" : "scripts"} marked · average mark {percentText(exam.meanPercent)} · usual time per script{" "}
        {secondsText(exam.medianSeconds)} · tolerance {stats.tolerancePercent}% of the maximum
      </p>
      {markers.length === 0 ? (
        <p className="text-sm text-slate-600">No marker has submitted a script yet.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
              <tr>
                {HEAD.map((h) => (
                  <th key={h} scope="col" className="py-2 pr-4 font-medium">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            {markers.map((m) => (
              <tbody key={m.markerId} data-testid="marker-stats" className="border-b border-slate-100 last:border-0">
                <tr className="align-top">
                  <th scope="row" className="py-2.5 pr-4 font-medium text-slate-900">
                    {m.name}
                  </th>
                  <td className="py-2.5 pr-4">{m.pieces}</td>
                  <td className="py-2.5 pr-4">
                    {percentText(m.meanPercent)}
                    {m.difference !== null && <span className="block text-xs text-slate-600">{differenceText(m.difference)}</span>}
                  </td>
                  <td className="py-2.5 pr-4">
                    {agreementText(m.second.within, m.second.compared)}
                    {m.second.compared > 0 && m.second.meanGap !== null && (
                      <span className="block text-xs text-slate-600">{gapText(m.second.meanGap)}</span>
                    )}
                  </td>
                  <td className="py-2.5 pr-4">{agreementText(m.seeds.within, m.seeds.done)}</td>
                  <td className="py-2.5 pr-4">{agreementText(m.practice.within, m.practice.done)}</td>
                  <td className="py-2.5 pr-4">{secondsText(m.medianSeconds)}</td>
                  <td className="py-2.5 pr-4">{m.sentBack}</td>
                </tr>
                {m.notes.length > 0 && (
                  <tr>
                    <td colSpan={HEAD.length} className="pb-3 pr-4">
                      <div className="rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
                        <p className="font-medium">Worth a look</p>
                        <ul className="list-disc pl-5">
                          {m.notes.map((n) => (
                            <li key={n}>{statsNote(n)}</li>
                          ))}
                        </ul>
                      </div>
                    </td>
                  </tr>
                )}
              </tbody>
            ))}
          </table>
        </div>
      )}
    </div>
  );
}
