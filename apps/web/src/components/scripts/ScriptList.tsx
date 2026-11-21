import Link from "next/link";
import { Badge } from "@/components/AppShell";
import { formatLondon } from "@/lib/money";
import { SOURCE_LABEL, STATE_TONE, candidateText, stateText, type ScriptListItem } from "@/lib/script-repository";

/**
 * Every script under the filters, newest received first: its number (opens the script), the candidate (staff only:
 * name and index number), the exam, home or centre, its state, whether it was late, how many pages it shows and when
 * it was received.
 */
export function ScriptList({ items, more }: { items: ScriptListItem[]; more: boolean }) {
  if (items.length === 0) {
    return <p className="text-sm text-slate-600">No scripts match these filters.</p>;
  }
  return (
    <div className="space-y-2">
      <div className="overflow-x-auto">
        <table className="w-full text-left text-sm" data-testid="script-list">
          <caption className="sr-only">Scripts</caption>
          <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
            <tr>
              {["Script", "Candidate", "Exam", "Source", "State", "Late", "Pages", "Received"].map((h) => (
                <th key={h} scope="col" className="py-2 pr-4 font-medium">
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {items.map((s) => (
              <tr key={s.id} className="border-b border-slate-100 last:border-0">
                <td className="py-2 pr-4 font-medium">
                  <Link href={`/admin/scripts/${s.id}`} className="text-blue-700 underline">
                    {s.number}
                  </Link>
                </td>
                <td className="py-2 pr-4">{candidateText(s.candidate)}</td>
                <td className="py-2 pr-4">
                  {s.exam ? `${s.exam.title}${s.exam.paper ? ` (${s.exam.paper})` : ""}` : ""}
                </td>
                <td className="py-2 pr-4">
                  <Badge tone={s.source === "home" ? "blue" : "slate"}>{SOURCE_LABEL[s.source]}</Badge>
                </td>
                <td className="py-2 pr-4">
                  <Badge tone={STATE_TONE[s.state]}>{stateText(s.state, s.stateReason)}</Badge>
                  {s.openExceptions > 0 && (
                    <span className="ml-2 text-xs text-amber-800">
                      {s.openExceptions} open {s.openExceptions === 1 ? "problem" : "problems"}
                    </span>
                  )}
                </td>
                <td className="py-2 pr-4">
                  {s.late ? `Yes${s.lateDecision === "accept" ? ", accepted" : s.lateDecision === "reject" ? ", not marked" : ""}` : "No"}
                </td>
                <td className="py-2 pr-4">
                  {s.pages}
                  {s.extraPages > 0 ? ` + ${s.extraPages} extra` : ""}
                </td>
                <td className="py-2 pr-4">{s.receivedAt ? formatLondon(s.receivedAt) : "Not yet"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {more && <p className="text-xs text-slate-500">Showing the newest 500. Filter by exam to see the rest.</p>}
    </div>
  );
}
