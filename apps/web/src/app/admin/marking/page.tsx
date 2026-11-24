import { Suspense } from "react";
import { AppShell, Card } from "@/components/AppShell";
import { AlertsList } from "@/components/marking/AlertsList";
import { MarkingProgress } from "@/components/marking/MarkingProgress";
import { UnitsTable, type Choice } from "@/components/marking/UnitsTable";
import { listHasMore, parseAlerts, parseProgress, parseUnits, type ProgressExam } from "@/lib/marking-lists";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

type Params = Record<string, string | string[] | undefined>;

const STATES = ["open", "taken", "submitted", "on_hold"];
const first = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v) ?? "";
const failed = (what: string) => (
  <p role="alert" className="text-sm text-red-700">
    {what} could not be loaded. Refresh the page to try again.
  </p>
);

type MarkerEntry = { id: string; name: string; status: string; subjects: number[] };

/** The markers of markers_list: id, name, status and approved subjects only (its conflicts never leave the server). */
function markerEntries(data: unknown): MarkerEntry[] {
  const d = data && typeof data === "object" && !Array.isArray(data) ? (data as Record<string, unknown>) : null;
  if (!d || d.ok !== true || !Array.isArray(d.markers)) return [];
  return (d.markers as Record<string, unknown>[]).flatMap((m) =>
    isUuid(m.id) && typeof m.name === "string"
      ? [
          {
            id: m.id,
            name: m.name,
            status: typeof m.status === "string" ? m.status : "",
            subjects: Array.isArray(m.subjects) ? (m.subjects as Record<string, unknown>[]).map((s) => s.id).filter((s): s is number => typeof s === "number") : [],
          },
        ]
      : [],
  );
}

/** One exam's scripts with their filters, the markers it may go to, and its question groups. */
async function ScriptsCard({ exam, exams, sp }: { exam: ProgressExam; exams: ProgressExam[]; sp: Params }) {
  await requireStaff(["admin", "owner"]);
  const supabase = await createClient();
  const state = STATES.includes(first(sp.state)) ? first(sp.state) : null;
  const marker = isUuid(first(sp.marker)) ? first(sp.marker) : null;
  const [unitsRes, examRes, markersRes, groupsRes] = await Promise.all([
    supabase.rpc("marking_units_list", { p_exam: exam.examId, ...(state ? { p_state: state } : {}), ...(marker ? { p_marker: marker } : {}) }),
    supabase.from("exams").select("subject_id").eq("id", exam.examId).maybeSingle(),
    supabase.rpc("markers_list"),
    supabase.from("question_groups").select("id, label, position").eq("exam_id", exam.examId).order("position", { ascending: true }),
  ]);
  const units = unitsRes.error ? null : parseUnits(unitsRes.data);
  if (!units || examRes.error || groupsRes.error) return failed("The scripts");
  const subject = examRes.data?.subject_id ?? null;
  const entries = markersRes.error ? [] : markerEntries(markersRes.data);
  const approved = entries.filter((m) => subject !== null && m.subjects.includes(subject));
  const markers: Choice[] = approved.filter((m) => m.status === "active").map((m) => ({ id: m.id, label: m.name }));
  const filterMarkers = new Map<string, string>(approved.map((m) => [m.id, m.name]));
  for (const m of exam.markers) if (!filterMarkers.has(m.markerId)) filterMarkers.set(m.markerId, m.name);
  return (
    <UnitsTable
      key={exam.examId}
      exam={{ id: exam.examId, title: exam.title, mode: exam.mode }}
      exams={exams.map((e) => ({ id: e.examId, label: `${e.title}${e.paper ? ` (${e.paper})` : ""}` }))}
      units={units}
      markers={markers}
      filterMarkers={[...filterMarkers].map(([id, label]) => ({ id, label }))}
      groups={(groupsRes.data ?? []).map((g) => ({ id: g.id, label: g.label }))}
      filters={{ state, marker }}
      more={listHasMore(unitsRes.data)}
    />
  );
}

async function Body({ searchParams }: { searchParams: Promise<Params> }) {
  await requireStaff(["admin", "owner"]);
  const sp = await searchParams;
  const supabase = await createClient();
  const [progressRes, alertsRes] = await Promise.all([supabase.rpc("marking_progress", {}), supabase.rpc("marking_alerts_list", {})]);
  const progress = progressRes.error ? null : parseProgress(progressRes.data);
  const alerts = alertsRes.error ? null : parseAlerts(alertsRes.data);
  if (!progress) return failed("Marking");
  const now = new Date().toISOString();
  // The exam asked for, else the first whose marking is open, else the first.
  const exam = progress.find((e) => e.examId === first(sp.exam)) ?? progress.find((e) => e.openedAt && !e.closedAt) ?? progress[0] ?? null;

  return (
    <div className="space-y-6">
      <Card title="Progress">
        <MarkingProgress exams={progress} now={now} scriptsLink releaseAll reviewLink statsLink />
      </Card>
      {exam && (
        <div id="scripts">
          <Card title={`Scripts: ${exam.title}${exam.paper ? ` (${exam.paper})` : ""}`}>
            <Suspense fallback={<p className="text-sm text-slate-500">Loading the scripts...</p>}>
              <ScriptsCard exam={exam} exams={progress} sp={sp} />
            </Suspense>
          </Card>
        </div>
      )}
      <Card title="Needs attention">{alerts ? <AlertsList alerts={alerts} more={listHasMore(alertsRes.data)} scriptLinks /> : failed("The alerts")}</Card>
    </div>
  );
}

export default function AdminMarking({ searchParams }: { searchParams: Promise<Params> }) {
  return (
    <AppShell role="admin" title="Marking">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading marking...</p>}>
        <Body searchParams={searchParams} />
      </Suspense>
    </AppShell>
  );
}
