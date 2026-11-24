import Link from "next/link";
import { Suspense } from "react";
import { markingMessageFor } from "@stem/shared";
import { AppShell, Card } from "@/components/AppShell";
import { ApprovalPanel } from "@/components/marking/ApprovalPanel";
import { parseApproval } from "@/lib/marking-approval";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

type Params = Promise<{ examId: string }>;

/** The exam's title and its approval, as marking_approval_get gives it (admins; the database checks again). */
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
        <p className="text-sm text-slate-700">{markingMessageFor("not_found")}</p>
      </div>
    );
  }
  const supabase = await createClient();
  const [approvalRes, examRes] = await Promise.all([
    supabase.rpc("marking_approval_get", { p_exam: examId }),
    supabase.from("exams").select("title, paper").eq("id", examId).maybeSingle(),
  ]);
  const r = approvalRes.error ? null : parseApproval(approvalRes.data);
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
      {!r ? (
        <Card>
          <p role="alert" className="text-sm text-red-700">
            The approval could not be loaded. Refresh the page to try again.
          </p>
        </Card>
      ) : !r.ok ? (
        <Card>
          <p className="text-sm text-slate-700">{markingMessageFor(r.code)}</p>
        </Card>
      ) : (
        <ApprovalPanel examId={examId} approval={r.approval} />
      )}
    </div>
  );
}

/** Approving an exam's marking, for admins and the owner, linked from each exam on the Marking page. */
export default function MarkingApprovalPage({ params }: { params: Params }) {
  return (
    <AppShell role="admin" title="Approve marking">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading the approval...</p>}>
        <Body params={params} />
      </Suspense>
    </AppShell>
  );
}
