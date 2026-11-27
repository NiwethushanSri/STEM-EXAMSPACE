import Link from "next/link";
import { Suspense } from "react";
import { AppShell, Badge, Card } from "@/components/AppShell";
import { formatLondon } from "@/lib/money";
import { RESULTS_STATES, stateText, type ResultsState } from "@/lib/results-admin";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

const LIMIT = 1000;

const TONE: Record<ResultsState, "slate" | "blue" | "amber" | "green" | "red"> = {
  none: "slate",
  prepared: "blue",
  scheduled: "amber",
  published: "green",
  withdrawn: "red",
};

type One<T> = T | T[] | null;
const one = <T,>(v: One<T>): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

async function Body() {
  await requireStaff(["admin", "owner"]);
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("exams")
    .select("id, title, paper, starts_at, exam_marking(approved_at), exam_results(state, publish_at, published_at)")
    .order("starts_at", { ascending: false })
    .limit(LIMIT);
  if (error || !data) {
    return (
      <p role="alert" className="text-sm text-red-700">
        The exams could not be loaded. Refresh the page to try again.
      </p>
    );
  }
  // Every exam whose marking is approved or that has a results row.
  const exams = data.flatMap((e) => {
    const approvedAt = one(e.exam_marking as One<{ approved_at: string | null }>)?.approved_at ?? null;
    const res = one(e.exam_results as One<{ state: string; publish_at: string | null; published_at: string | null }>);
    if (!approvedAt && !res) return [];
    const state = (RESULTS_STATES as readonly string[]).includes(res?.state ?? "") ? (res?.state as ResultsState) : "none";
    return [{ id: e.id, title: e.title, paper: e.paper, startsAt: e.starts_at, state, publishAt: res?.publish_at ?? null, publishedAt: res?.published_at ?? null }];
  });

  return (
    <Card title="Exams with marking approved or results">
      {exams.length === 0 ? (
        <p className="text-sm text-slate-700">No exam has approved marking yet. Approve an exam&apos;s marking first, then prepare its results here.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="py-2 pr-4 font-medium">Exam</th>
                <th className="py-2 pr-4 font-medium">Exam date</th>
                <th className="py-2 pr-4 font-medium">Results</th>
                <th className="py-2 font-medium">
                  <span className="sr-only">Open</span>
                </th>
              </tr>
            </thead>
            <tbody>
              {exams.map((e) => (
                <tr key={e.id} className="border-b border-slate-100 last:border-0">
                  <td className="py-2.5 pr-4 font-medium text-slate-900">
                    {e.title}
                    {e.paper ? ` (${e.paper})` : ""}
                  </td>
                  <td className="py-2.5 pr-4">{formatLondon(e.startsAt)}</td>
                  <td className="py-2.5 pr-4">
                    <Badge tone={TONE[e.state]}>{stateText(e)}</Badge>
                  </td>
                  <td className="py-2.5 text-right">
                    <Link href={`/admin/results/${e.id}`} className="text-blue-700 underline">
                      Open results
                    </Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {data.length >= LIMIT && <p className="mt-3 text-sm text-amber-900">Only the latest {LIMIT.toLocaleString("en-GB")} exams are checked.</p>}
    </Card>
  );
}

/** The exams whose marking is approved or that have results, with where each one's results stand. */
export default function AdminResults() {
  return (
    <AppShell role="admin" title="Results">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading the results...</p>}>
        <Body />
      </Suspense>
    </AppShell>
  );
}
