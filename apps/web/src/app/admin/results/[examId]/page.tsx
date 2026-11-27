import Link from "next/link";
import { Suspense } from "react";
import { resultsMessageFor } from "@stem/shared";
import { AppShell, Card } from "@/components/AppShell";
import { ResultsPanel } from "@/components/results/ResultsPanel";
import { parseResults, refusalCode } from "@/lib/results-admin";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

type Params = Promise<{ examId: string }>;

const back = (
  <Link href="/admin/results" className="text-sm text-blue-700 underline">
    All results
  </Link>
);

/** The exam's title and its results, as results_get gives them (admins; the database checks again). */
async function Body({ params }: { params: Params }) {
  await requireStaff(["admin", "owner"]);
  const { examId } = await params;
  if (!isUuid(examId)) {
    return (
      <div className="space-y-5">
        {back}
        <p className="text-sm text-slate-700">{resultsMessageFor("not_found")}</p>
      </div>
    );
  }
  const supabase = await createClient();
  const [resultsRes, examRes] = await Promise.all([
    supabase.rpc("results_get", { p_exam: examId }),
    supabase.from("exams").select("title, paper").eq("id", examId).maybeSingle(),
  ]);
  const refused = resultsRes.error ? null : refusalCode(resultsRes.data);
  const results = resultsRes.error ? null : parseResults(resultsRes.data);
  const exam = examRes.error ? null : examRes.data;
  return (
    <div className="space-y-5">
      <div>
        {back}
        {exam && (
          <h2 className="mt-2 text-lg font-semibold text-slate-900">
            {exam.title}
            {exam.paper ? ` (${exam.paper})` : ""}
          </h2>
        )}
        <p className="mt-1 text-sm">
          <Link href={`/admin/marking/${examId}/approval`} className="text-blue-700 underline">
            Marking approval
          </Link>
        </p>
      </div>
      {refused ? (
        <Card>
          <p className="text-sm text-slate-700">{resultsMessageFor(refused)}</p>
        </Card>
      ) : !results ? (
        <Card>
          <p role="alert" className="text-sm text-red-700">
            The results could not be loaded. Refresh the page to try again.
          </p>
        </Card>
      ) : (
        <ResultsPanel examId={examId} results={results} />
      )}
    </div>
  );
}

/** One exam's results for admins and the owner: prepare, grade boundaries, candidates, sign-off and publication. */
export default function ExamResultsPage({ params }: { params: Params }) {
  return (
    <AppShell role="admin" title="Results">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading the results...</p>}>
        <Body params={params} />
      </Suspense>
    </AppShell>
  );
}
