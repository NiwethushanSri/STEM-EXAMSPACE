import Link from "next/link";
import { Badge, Table } from "@/components/AppShell";
import { ReleaseAllButton } from "@/components/marking/ReleaseAllButton";
import { deadlineText, ukDayTime, type ProgressExam } from "@/lib/marking-lists";

/** "Mark by 12 December, 17:00" and, once the deadline has passed with work left, "Overdue" in red words. `overdue` is
 * the database's view (marking still open and work left); the line says it only once the deadline has passed. */
export function DeadlineLine({ deadline, overdue, now }: { deadline: string | null; overdue: boolean; now: Date }) {
  const d = deadlineText(deadline, now);
  return (
    <p className="text-sm text-slate-700">
      {d.text}
      {d.overdue && overdue && <span className="ml-2 font-semibold text-red-700">Overdue</span>}
    </p>
  );
}

function status(e: ProgressExam): { text: string; tone: "slate" | "green" | "blue" } {
  if (e.closedAt) return { text: "Marking closed", tone: "slate" };
  if (e.openedAt) return { text: "Marking open", tone: "green" };
  return { text: "Not open yet", tone: "blue" };
}

/** What is left per exam and per marker: the scripts waiting, ready to mark, being marked and marked; each marker's
 * scripts taken and submitted; the alerts open. No candidate name. `scriptsLink` links each exam to its list of
 * scripts on the admin marking page. `releaseAll` offers "Release all" on each exam with an open alert, so the holds of
 * changed pictures can be released even when the alerts list cannot be loaded. `now` is the server's clock when the
 * page was made. */
export function MarkingProgress({
  exams,
  now,
  scriptsLink = false,
  releaseAll = false,
}: {
  exams: ProgressExam[];
  now: string;
  scriptsLink?: boolean;
  releaseAll?: boolean;
}) {
  const at = new Date(now);
  if (exams.length === 0) return <p className="text-sm text-slate-600">No exam has marking set up yet.</p>;
  return (
    <ul className="space-y-5">
      {exams.map((e) => {
        const s = status(e);
        return (
          <li key={e.examId} data-testid="progress-exam" className="space-y-3 border-b border-slate-100 pb-5 last:border-0 last:pb-0">
            <div className="flex flex-wrap items-center gap-2">
              <h3 className="text-sm font-semibold text-slate-900">{e.title}</h3>
              <span className="text-sm text-slate-600">
                {e.subject}
                {e.paper ? ` · ${e.paper}` : ""}
              </span>
              <Badge tone={s.tone}>{s.text}</Badge>
              {e.mode === "by_question" && <Badge tone="slate">By question</Badge>}
            </div>
            <DeadlineLine deadline={e.deadline} overdue={e.overdue} now={at} />
            <dl className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              {(
                [
                  ["Waiting", e.scripts.waiting],
                  ["Ready to mark", e.scripts.readyToMark],
                  ["Being marked", e.scripts.marking],
                  ["Marked", e.scripts.marked],
                ] as const
              ).map(([label, n]) => (
                <div key={label} className="rounded border border-slate-200 px-3 py-2">
                  <dt className="text-xs uppercase tracking-wide text-slate-500">{label}</dt>
                  <dd className="text-lg font-semibold text-blue-700">{n}</dd>
                </div>
              ))}
            </dl>
            {(e.units.onHold > 0 || e.alertsOpen > 0) && (
              <p className="text-sm text-amber-900">
                {[
                  e.units.onHold > 0 ? `${e.units.onHold} on hold` : null,
                  e.alertsOpen > 0 ? `${e.alertsOpen} ${e.alertsOpen === 1 ? "alert needs" : "alerts need"} attention` : null,
                ]
                  .filter(Boolean)
                  .join(" · ")}
              </p>
            )}
            {releaseAll && e.alertsOpen > 0 && <ReleaseAllButton examId={e.examId} examTitle={e.title} />}
            {e.markers.length === 0 ? (
              <p className="text-sm text-slate-600">No marker has taken a script yet.</p>
            ) : (
              <Table
                head={["Marker", "Taken now", "Submitted", "Last saved"]}
                rows={e.markers.map((m) => [m.name, m.taken, m.submitted, m.lastSavedAt ? ukDayTime(m.lastSavedAt) : "—"])}
              />
            )}
            {scriptsLink && (
              <Link href={`/admin/marking?exam=${e.examId}#scripts`} className="inline-block text-sm font-medium text-blue-700 underline">
                Show the scripts of {e.title}
              </Link>
            )}
          </li>
        );
      })}
    </ul>
  );
}

