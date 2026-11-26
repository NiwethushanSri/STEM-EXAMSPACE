import Link from "next/link";
import { Suspense } from "react";
import { reviewMessageFor } from "@stem/shared";
import { AppShell, Card } from "@/components/AppShell";
import { MarkerStats } from "@/components/marking/MarkerStats";
import { parseStats } from "@/lib/marking-stats";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

type Params = Promise<{ examId: string }>;

/** The exam's title and its marker statistics, as marking_stats gives them (admins; the database checks again). */
async function Body({ params }: { params: Params }) {
  await requireStaff(["admin", "owner"]);
  const { examId } = await params;
  const back = (
    <Link href={isUuid(examId) ? `/admin/marking?exam=${examId}` : "/admin/marking"} className="text-sm text-blue-700 underline">
      Back to marking
    </Link>
  );
  if (!isUuid(examId)) {
    return (
      <div className="space-y-5">
        {back}
        <p className="text-sm text-slate-700">{reviewMessageFor("not_found")}</p>
      </div>
    );
  }
  const supabase = await createClient();
  const [statsRes, examRes] = await Promise.all([
    supabase.rpc("marking_stats", { p_exam: examId }),
    supabase.from("exams").select("title, paper").eq("id", examId).maybeSingle(),
  ]);
  const r = statsRes.error ? null : parseStats(statsRes.data);
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
      </div>
      <Card>
        {!r ? (
          <p role="alert" className="text-sm text-red-700">
            The statistics could not be loaded. Refresh the page to try again.
          </p>
        ) : !r.ok ? (
          <p className="text-sm text-slate-700">{reviewMessageFor(r.code)}</p>
        ) : (
          <MarkerStats stats={r.stats} />
        )}
      </Card>
    </div>
  );
}

/** An exam's marker statistics for admins and the owner, linked from each exam on the Marking page. */
export default function MarkingStatisticsPage({ params }: { params: Params }) {
  return (
    <AppShell role="admin" title="Marker statistics">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading the statistics...</p>}>
        <Body params={params} />
      </Suspense>
    </AppShell>
  );
}
