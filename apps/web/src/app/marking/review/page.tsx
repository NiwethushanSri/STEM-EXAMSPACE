import Link from "next/link";
import { Suspense } from "react";
import { reviewMessageFor, standardMessageFor } from "@stem/shared";
import { AppShell, Card } from "@/components/AppShell";
import { ExamMarkers } from "@/components/marking/ExamMarkers";
import { MarkerStats } from "@/components/marking/MarkerStats";
import { ReviewList } from "@/components/marking/ReviewList";
import { Standards } from "@/components/marking/Standards";
import { MARKING_ROLES, parseProgress, type ProgressExam } from "@/lib/marking-lists";
import {
  parseExamMarkers,
  parseReviewList,
  parseStandards,
  stuckText,
  type ReviewCounts,
  type ReviewKind,
  type ReviewList as ReviewListData,
} from "@/lib/marking-review";
import { parseStats } from "@/lib/marking-stats";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

type Params = Record<string, string | string[] | undefined>;
type Tab = { id: string; label: (c: ReviewCounts) => string; kind?: ReviewKind; empty?: string };
type ExamTabId = "markers" | "standards" | "statistics";

const TABS: Tab[] = [
  { id: "difference", kind: "difference", label: (c) => `Marks that differ (${c.difference})`, empty: "No marks differ for you to settle." },
  { id: "paused", kind: "paused_marker", label: (c) => `Paused markers' scripts (${c.pausedMarker})`, empty: "No paused marker's script waits for you." },
  { id: "sample", kind: "sample", label: (c) => `Your sample (${c.sample})`, empty: "No script of your sample waits for you. On Markers, choose a marker to review 5 of their scripts." },
  { id: "markers", label: () => "Markers" },
  { id: "standards", label: () => "Practice and seeded scripts" },
  { id: "statistics", label: () => "Statistics" },
];

const LOADING = <p className="text-sm text-slate-500">Loading the review...</p>;
const first = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v) ?? "";
const failed = (what: string) => (
  <p role="alert" className="text-sm text-red-700">
    {what} could not be loaded. Refresh the page to try again.
  </p>
);
const FIELD = "min-h-11 rounded border border-slate-300 bg-white px-2 py-1.5 text-sm";
const BUTTON = "min-h-11 rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700";
const href = (tab: string, exam: string | null) => `/marking/review?tab=${tab}${exam ? `&exam=${exam}` : ""}`;

/** One exam's markers, its practice and seeded scripts, or its marker statistics. */
async function ExamTab({ tab, exam, selfId }: { tab: ExamTabId; exam: ProgressExam; selfId: string }) {
  await requireStaff(MARKING_ROLES);
  const supabase = await createClient();
  if (tab === "markers") {
    const { data, error } = await supabase.rpc("marking_exam_markers", { p_exam: exam.examId });
    const r = error ? null : parseExamMarkers(data);
    if (!r) return failed("The markers");
    if (!r.ok) return <p className="text-sm text-slate-700">{standardMessageFor(r.code)}</p>;
    return <ExamMarkers key={exam.examId} examId={exam.examId} markers={r.markers} selfId={selfId} />;
  }
  if (tab === "statistics") {
    const { data, error } = await supabase.rpc("marking_stats", { p_exam: exam.examId });
    const r = error ? null : parseStats(data);
    if (!r) return failed("The statistics");
    if (!r.ok) return <p className="text-sm text-slate-700">{reviewMessageFor(r.code)}</p>;
    return <MarkerStats stats={r.stats} />;
  }
  const { data, error } = await supabase.rpc("marking_standards_list", { p_exam: exam.examId });
  const r = error ? null : parseStandards(data);
  if (!r) return failed("The practice and seeded scripts");
  if (!r.ok) return <p className="text-sm text-slate-700">{standardMessageFor(r.code)}</p>;
  return <Standards key={exam.examId} standards={r.standards} canAdd={r.canAdd} more={r.more} />;
}

/** The stuck line, the exam to show, the tabs and the chosen tab. The review lists are of every exam the caller may
 * review, or of the exam asked for; the markers, the practice and seeded scripts and the statistics are of one exam (the
 * one asked for, else the first whose marking is open, else the first). No candidate name. */
function Body({
  tab,
  asked,
  list,
  exams,
  selfId,
  role,
}: {
  tab: Tab;
  asked: string | null;
  list: ReviewListData;
  exams: ProgressExam[];
  selfId: string;
  role: string;
}) {
  const perExam = !tab.kind;
  const exam = exams.find((e) => e.examId === asked) ?? (perExam ? (exams.find((e) => e.openedAt && !e.closedAt) ?? exams[0] ?? null) : null);
  const { counts } = list;
  return (
    <div className="space-y-6">
      {counts.stuckSecond > 0 && (
        <p role="alert" className="rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          {stuckText(counts.stuckSecond, role)}
        </p>
      )}
      <form method="get" action="/marking/review" aria-label="Choose the exam" className="flex flex-wrap items-end gap-3 text-sm">
        <input type="hidden" name="tab" value={tab.id} />
        <label className="flex flex-col gap-1">
          Exam
          <select name="exam" defaultValue={exam?.examId ?? ""} className={`${FIELD} max-w-80`}>
            {!perExam && <option value="">All exams</option>}
            {exams.map((e) => (
              <option key={e.examId} value={e.examId}>
                {`${e.title}${e.paper ? ` (${e.paper})` : ""}`}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className={BUTTON}>
          Show
        </button>
      </form>
      <nav aria-label="Review" className="flex flex-wrap gap-2 border-b border-slate-200">
        {TABS.map((t) => {
          const active = t.id === tab.id;
          return (
            <Link
              key={t.id}
              href={href(t.id, asked)}
              aria-current={active ? "page" : undefined}
              className={`-mb-px min-h-11 border-b-2 px-3 py-2 text-sm font-medium ${active ? "border-blue-700 text-blue-800" : "border-transparent text-slate-600 hover:text-slate-900"}`}
            >
              {t.label(counts)}
            </Link>
          );
        })}
      </nav>
      <Card>
        {tab.kind ? (
          <ReviewList items={list.items.filter((i) => i.kind === tab.kind)} showExam={!asked} exam={asked} more={list.more} empty={tab.empty ?? ""} />
        ) : exam ? (
          <Suspense fallback={LOADING}>
            <ExamTab tab={tab.id as ExamTabId} exam={exam} selfId={selfId} />
          </Suspense>
        ) : (
          <p className="text-sm text-slate-600">No exam has marking set up yet.</p>
        )}
      </Card>
    </div>
  );
}

/** The staff shell with the signed-in role's menu (a lead marker's shows Review under Marking), around what the review
 * list and the exams say. The database decides who may review: an admin, or the subject's lead marker. */
async function Shell({ searchParams }: { searchParams: Promise<Params> }) {
  const me = await requireStaff(MARKING_ROLES);
  const sp = await searchParams;
  const tab = TABS.find((t) => t.id === first(sp.tab)) ?? TABS[0];
  const asked = isUuid(first(sp.exam)) ? first(sp.exam) : null;
  const supabase = await createClient();
  const [listRes, progressRes] = await Promise.all([
    supabase.rpc("marking_review_list", { ...(asked ? { p_exam: asked } : {}), ...(tab.kind ? { p_kind: tab.kind } : {}) }),
    supabase.rpc("marking_progress", {}),
  ]);
  const list = listRes.error ? null : parseReviewList(listRes.data);
  const exams = (progressRes.error ? null : parseProgress(progressRes.data)) ?? [];
  const lead = list?.ok === true && (me.role === "corrector" || me.role === "teacher");
  return (
    <AppShell role={me.role} title="Review" lead={lead}>
      {!list ? (
        failed("The review")
      ) : !list.ok ? (
        <p className="text-sm text-slate-700">{reviewMessageFor(list.code)}</p>
      ) : (
        <Body tab={tab} asked={asked} list={list.list} exams={exams} selfId={me.id} role={me.role} />
      )}
    </AppShell>
  );
}

/** The lead marker's review: marks that differ, paused markers' scripts, the routine sample, the markers, the practice
 * and seeded scripts, and the marker statistics. Admins and the owner reach it from each exam on the Marking page. */
export default function ReviewHome({ searchParams }: { searchParams: Promise<Params> }) {
  return (
    <Suspense fallback={<div className="p-6">{LOADING}</div>}>
      <Shell searchParams={searchParams} />
    </Suspense>
  );
}
