import Link from "next/link";
import { firstShownText, ukDayTime } from "@/lib/marking-lists";
import { totalText } from "@/lib/marking-feedback";
import { PARTY_TEXT, type ReviewItem, type ReviewMarker } from "@/lib/marking-review";

const QUIET = "inline-flex min-h-11 items-center rounded border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-800 hover:bg-slate-50";

const marker = (m: ReviewMarker | null, max: number | null) => (m ? `${m.name}: ${totalText(m.total, max)}` : "—");

/** The open reviews of one kind, oldest first: script number, index number, both markers and their totals, and "Open"
 * (the review screen). A review of a script the caller marked says so. `showExam`: the list covers every exam the caller
 * may review, so each row says its exam. `exam`: the exam the list is narrowed to, kept for the review screen's way
 * back. `more`: the list was cut short at 500. No candidate name. */
export function ReviewList({
  items,
  showExam,
  exam,
  more,
  empty,
}: {
  items: ReviewItem[];
  showExam: boolean;
  exam: string | null;
  more: boolean;
  empty: string;
}) {
  if (items.length === 0) return <p className="text-sm text-slate-600">{empty}</p>;
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-left text-sm">
        <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
          <tr>
            <th className="py-2 pr-4 font-medium">Script</th>
            <th className="py-2 pr-4 font-medium">Index number</th>
            {showExam && <th className="py-2 pr-4 font-medium">Exam</th>}
            <th className="py-2 pr-4 font-medium">First marker</th>
            <th className="py-2 pr-4 font-medium">Second marker</th>
            <th className="py-2 pr-4 font-medium">Waiting since</th>
            <th className="py-2 pr-4 font-medium">
              <span className="sr-only">Open</span>
            </th>
          </tr>
        </thead>
        <tbody>
          {items.map((r) => (
            <tr key={r.reviewId} data-testid="review-item" className="border-b border-slate-100 last:border-0">
              <td className="py-2.5 pr-4">
                <span className="font-medium text-slate-900">{r.scriptNumber}</span>
                {r.groupLabel && <span className="ml-2 text-slate-600">{r.groupLabel}</span>}
                {r.party && <p className="text-amber-900">{PARTY_TEXT}</p>}
              </td>
              <td className="py-2.5 pr-4">{r.indexNumber ?? "—"}</td>
              {showExam && <td className="py-2.5 pr-4">{r.examTitle}</td>}
              <td className="py-2.5 pr-4 tabular-nums">{marker(r.first, r.maxTotal)}</td>
              <td className="py-2.5 pr-4 tabular-nums">{marker(r.second, r.maxTotal)}</td>
              <td className="py-2.5 pr-4">{r.openedAt ? ukDayTime(r.openedAt) : "—"}</td>
              <td className="py-2.5 pr-4">
                <Link href={`/marking/review/${r.reviewId}${exam ? `?exam=${exam}` : ""}`} className={QUIET} aria-label={`Open script ${r.scriptNumber}`}>
                  Open
                </Link>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      {more && <p className="mt-2 text-sm text-slate-600">{firstShownText(items.length)}</p>}
    </div>
  );
}
