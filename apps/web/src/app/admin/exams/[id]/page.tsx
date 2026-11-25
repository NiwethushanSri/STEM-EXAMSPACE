import { Suspense } from "react";
import Link from "next/link";
import { AppShell, Badge } from "@/components/AppShell";
import { ExamMarkingPanel } from "@/components/marking/ExamMarkingPanel";
import { DownloadLog } from "@/components/papers/DownloadLog";
import { PaperPanel } from "@/components/papers/PaperPanel";
import { PrintPanel } from "@/components/papers/PrintPanel";
import { ReleasePanel } from "@/components/papers/ReleasePanel";
import { ScanBatches } from "@/components/scripts/ScanBatches";
import { loadExamAdmin, loadExamMarking, loadScanBatches } from "@/lib/exam-admin";
import { missingPaperWarning } from "@/lib/print-pack";
import { formatLondon } from "@/lib/money";

async function Body({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const [v, scans, marking] = await Promise.all([loadExamAdmin(id), loadScanBatches(id), loadExamMarking(id)]);
  const now = new Date();
  const nowMs = now.getTime();
  const current = v.papers.find((p) => p.kind === "paper" && p.current) ?? null;
  const locked = v.exam.status === "cancelled" || v.exam.status === "completed";
  const warn = missingPaperWarning({ status: v.exam.status, hasPaper: current !== null, releaseAt: v.releaseAt }, now);
  return (
    <div className="space-y-5">
      <div>
        <Link href="/admin/exams" className="text-sm text-blue-700 underline">
          Back to exams
        </Link>
        <Link href="/admin/exams/scan-check" className="ml-4 text-sm text-blue-700 underline">
          Check a scan
        </Link>
        <Link href={`/admin/exams/${v.exam.id}/structure`} className="ml-4 text-sm text-blue-700 underline">
          Questions and mark scheme
        </Link>
        <h2 className="mt-2 text-lg font-semibold text-slate-900">
          {v.exam.title}
          {v.exam.paper ? ` (${v.exam.paper})` : ""}
        </h2>
        <p className="text-sm text-slate-500">
          {v.exam.subject} · {formatLondon(v.exam.startsAt)} (UK time) · {v.exam.examCode}
          <span className="ml-2 align-middle">
            <Badge tone={v.exam.status === "published" ? "green" : v.exam.status === "draft" ? "slate" : v.exam.status === "cancelled" ? "red" : "blue"}>
              {v.exam.status[0].toUpperCase() + v.exam.status.slice(1)}
            </Badge>
          </span>
        </p>
      </div>

      {warn && (
        <div role="alert" data-testid="missing-paper-warning" className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          This exam has no paper and is due for release at {formatLondon(v.releaseAt)}. Families will see that the paper is not ready.
        </div>
      )}

      {current && current.pagesReviewedAt === null && !locked && (
        <div role="status" data-testid="page-roles-warning" className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          Check the page roles before the release time. Say which pages are answer pages and hide any candidate name boxes. Until
          the roles are saved, the paper cannot be released and no copy is made for candidates (at home, in a print pack or as a
          reprint).
        </div>
      )}

      <PaperPanel examId={v.exam.id} papers={v.papers} currentHasCopies={v.currentHasCopies} layout={v.layout} locked={locked} />
      <ReleasePanel
        examId={v.exam.id}
        status={v.exam.status}
        releaseAt={v.releaseAt}
        releasedEarlyAt={v.exam.releasedEarlyAt}
        held={v.exam.held}
        hasPaper={current !== null}
        examCode={v.exam.examCode}
        releaseMinutes={v.exam.releaseMinutesBefore}
        sparePages={v.exam.sparePages}
        codeLocked={v.hasCopies}
        nowMs={nowMs}
      />
      <PrintPanel examTitle={v.exam.title} examCode={v.exam.examCode} startsAt={v.exam.startsAt} paperVersion={current?.version ?? null}
        rolesChecked={current !== null && current.pagesReviewedAt !== null} centres={v.centres} />
      {v.centres.length > 0 && (
        <ScanBatches examId={v.exam.id} centres={v.centres.map((c) => ({ id: c.id, venue: c.venue, room: c.room }))} batches={scans} />
      )}
      <ExamMarkingPanel
        examId={v.exam.id}
        view={marking.view}
        checks={marking.checks}
        rates={marking.rates}
        groups={marking.groups}
        finishesAt={marking.finishesAt}
        homeUntil={marking.homeUntil}
      />
      <DownloadLog entries={v.downloads} capped={v.downloadsCapped} />
    </div>
  );
}

export default function AdminExamPage({ params }: { params: Promise<{ id: string }> }) {
  return (
    <AppShell role="admin" title="Exam paper">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading exam...</p>}>
        <Body params={params} />
      </Suspense>
    </AppShell>
  );
}
