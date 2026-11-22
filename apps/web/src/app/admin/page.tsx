import { Suspense } from "react";
import Link from "next/link";
import { AppShell, Card } from "@/components/AppShell";
import { FamilyNotices } from "@/components/scripts/FamilyNotices";
import { AccountsOverview } from "@/components/accounts/AccountsSection";
import { DeadlineLine } from "@/components/marking/MarkingProgress";
import {
  markingAlerts,
  parseMarkingDashboard,
  parseScriptsDashboard,
  scriptsDashboardAlerts,
  type MarkingDashboard,
  type ScriptsDashboard,
  type StaffAlert,
} from "@/lib/alerts";
import { loadExamsMissingPaper, loadExamsRolesUnchecked } from "@/lib/exams-staff";
import { missingPaperWarning } from "@/lib/print-pack";
import { formatLondon } from "@/lib/money";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

/** Published exams with no paper whose release is within 24 hours. Shows nothing when there are none. */
async function MissingPapers() {
  const missing = await loadExamsMissingPaper();
  const now = new Date();
  const due = missing.filter((e) => missingPaperWarning({ status: "published", hasPaper: false, releaseAt: e.releaseAt }, now));
  if (due.length === 0) return null;
  return (
    <div className="mb-6" data-testid="missing-papers">
      <Card title="Papers missing">
        <p className="mb-2 text-sm text-amber-900">These exams are published and due for release within 24 hours, but have no paper.</p>
        <ul className="divide-y divide-slate-100 text-sm">
          {due.map((e) => (
            <li key={e.id} className="flex items-center justify-between py-2.5">
              <span>
                <span className="font-medium">{e.title}</span>
                {e.paper ? ` (${e.paper})` : ""} · release {formatLondon(e.releaseAt)}
              </span>
              <Link href={`/admin/exams/${e.id}`} className="text-blue-700 underline">
                Upload paper
              </Link>
            </li>
          ))}
        </ul>
      </Card>
    </div>
  );
}

/** Published exams due for release within 24 hours whose paper's page roles nobody has checked: the paper cannot be
 * released and no copy is made for candidates until an admin saves the roles. Shows nothing when there are none. */
async function RolesUnchecked() {
  const unchecked = await loadExamsRolesUnchecked();
  const now = new Date();
  const due = unchecked.filter((e) => missingPaperWarning({ status: "published", hasPaper: false, releaseAt: e.releaseAt }, now));
  if (due.length === 0) return null;
  return (
    <div className="mb-6" data-testid="roles-unchecked">
      <Card title="Page roles not checked">
        <p className="mb-2 text-sm text-amber-900">
          These exams are due for release within 24 hours, but nobody has checked their paper&apos;s page roles. Until then no copy is made
          for candidates.
        </p>
        <ul className="divide-y divide-slate-100 text-sm">
          {due.map((e) => (
            <li key={e.id} className="flex items-center justify-between py-2.5">
              <span>
                <span className="font-medium">{e.title}</span>
                {e.paper ? ` (${e.paper})` : ""} · release {formatLondon(e.releaseAt)}
              </span>
              <Link href={`/admin/exams/${e.id}`} className="text-blue-700 underline">
                Check page roles
              </Link>
            </li>
          ))}
        </ul>
      </Card>
    </div>
  );
}

/** One figure of the scripts dashboard; a link when there is somewhere to act on it. */
function Tile({ label, value, href, testId }: { label: string; value: string | number; href?: string; testId: string }) {
  const body = (
    <>
      <span className="block text-xs uppercase tracking-wide text-slate-500">{label}</span>
      <span className="mt-1 block text-2xl font-semibold text-blue-700" data-testid={testId}>
        {value}
      </span>
    </>
  );
  const box = "block rounded-lg border border-slate-200 bg-white p-4 shadow-sm";
  return href ? (
    <Link href={href} className={`${box} hover:border-blue-300 hover:bg-blue-50`}>
      {body}
    </Link>
  ) : (
    <div className={box}>{body}</div>
  );
}

/** A dashboard's alerts, red or amber, each with an "Open" link when there is somewhere to act on it. */
function StaffAlerts({ title, alerts, testId }: { title: string; alerts: StaffAlert[]; testId: string }) {
  return (
    <Card title={title}>
      <ul className="space-y-2 text-sm" data-testid={testId}>
        {alerts.map((a) => (
          <li key={a.id} className={`rounded border p-3 ${a.tone === "red" ? "border-red-200 bg-red-50 text-red-900" : "border-amber-200 bg-amber-50 text-amber-900"}`}>
            {a.text}
            {a.href && (
              <>
                {" "}
                <Link href={a.href} className="font-medium underline">
                  Open
                </Link>
              </>
            )}
          </li>
        ))}
      </ul>
    </Card>
  );
}

function ScriptsDashboardView({ d }: { d: ScriptsDashboard }) {
  const alerts = scriptsDashboardAlerts(d);
  return (
    <div className="mb-6 space-y-4" data-testid="scripts-dashboard">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Tile label="Problems to check" value={d.openExceptions} href="/admin/scripts/exceptions" testId="tile-open-exceptions" />
        <Tile label="Uploaded, not sent" value={d.unsubmittedDrafts} href="/admin/scripts/unsent" testId="tile-unsent" />
        <Tile label="Files not processed" value={d.failedJobs} href="/admin/scripts/exceptions?kind=processing_failed" testId="tile-failed-jobs" />
        <Tile
          label="Oldest file waiting"
          value={d.oldestQueuedMinutes === null ? "None" : `${d.oldestQueuedMinutes} min`}
          testId="tile-queue"
        />
      </div>

      {alerts.length > 0 && <StaffAlerts title="Scripts: needs action" alerts={alerts} testId="scripts-alerts" />}

      <Card title="Scripts in the last 14 days">
        {d.exams.length === 0 ? (
          <p className="text-sm text-slate-500">No exam has taken place in the last 14 days.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm" data-testid="scripts-exams">
              <caption className="sr-only">Scripts expected and received per exam</caption>
              <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  {["Exam", "Expected", "Received", "Verified", "Needs attention", "Late", "Uploaded, not sent"].map((h) => (
                    <th key={h} scope="col" className="py-2 pr-4 font-medium">
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {d.exams.map((e) => (
                  <tr key={e.id} data-testid="scripts-exam" className="border-b border-slate-100 last:border-0">
                    <th scope="row" className="py-2 pr-4 font-normal">
                      <Link href={`/admin/scripts?exam=${e.id}`} className="font-medium text-blue-700 underline">
                        {e.title}
                        {e.paper ? ` (${e.paper})` : ""}
                      </Link>
                      <span className="block text-xs text-slate-500">{formatLondon(e.startsAt)}</span>
                    </th>
                    <td className="py-2 pr-4">{e.expected}</td>
                    <td className="py-2 pr-4">{e.received}</td>
                    <td className="py-2 pr-4">{e.verified}</td>
                    <td className="py-2 pr-4">{e.needsAttention}</td>
                    <td className="py-2 pr-4">{e.late}</td>
                    <td className="py-2 pr-4">
                      {e.unsubmitted > 0 ? (
                        <Link href={`/admin/scripts/unsent?exam=${e.id}`} className="font-medium text-blue-700 underline">
                          {e.unsubmitted}
                        </Link>
                      ) : (
                        0
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}

/** The scripts part of the operations dashboard (public.scripts_dashboard). */
async function ScriptsOverview() {
  await requireStaff(["admin", "owner"]);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("scripts_dashboard", {});
  const d = error ? null : parseScriptsDashboard(data);
  if (!d) {
    return (
      <div className="mb-6">
        <Card title="Scripts">
          <p role="alert" className="text-sm text-red-700">The scripts figures could not be loaded. Refresh the page to try again.</p>
        </Card>
      </div>
    );
  }
  const waiting = await familyNoticesWaiting(supabase);
  return (
    <>
      {waiting > 0 && (
        <div className="mb-6">
          <Card title="Family emails">
            <FamilyNotices count={waiting} />
          </Card>
        </div>
      )}
      <ScriptsDashboardView d={d} />
    </>
  );
}

/** The marking figures (public.marking_dashboard): what is left, on hold and waiting for staff, the alerts, and a row
 * per exam whose marking is open or closed in the last 14 days. No candidate name. */
function MarkingDashboardView({ d, now }: { d: MarkingDashboard; now: Date }) {
  const alerts = markingAlerts(d);
  return (
    <div className="mb-6 space-y-4" data-testid="marking-dashboard">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Tile label="Left to mark" value={d.left} href="/admin/marking" testId="tile-marking-left" />
        <Tile label="On hold in marking" value={d.onHold} href="/admin/marking" testId="tile-marking-on-hold" />
        <Tile label="Marking alerts open" value={d.alertsOpen} href="/admin/marking" testId="tile-marking-alerts" />
        <Tile label="Marking pictures to check" value={d.picturesToCheck} href="/admin/scripts/exceptions?tab=checks" testId="tile-marking-pictures" />
      </div>

      {alerts.length > 0 && <StaffAlerts title="Marking: needs action" alerts={alerts} testId="marking-alerts" />}

      <Card title="Marking">
        {d.exams.length === 0 ? (
          <p className="text-sm text-slate-500">No exam is being marked, and no marking closed in the last 14 days.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm" data-testid="marking-exams">
              <caption className="sr-only">Marking left, marked and on hold per exam</caption>
              <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  {["Exam", "Left", "Marked", "On hold", "Deadline"].map((h) => (
                    <th key={h} scope="col" className="py-2 pr-4 font-medium">
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {d.exams.map((e) => (
                  <tr key={e.examId} data-testid="marking-exam" className="border-b border-slate-100 last:border-0">
                    <th scope="row" className="py-2 pr-4 font-normal">
                      <Link href={`/admin/marking?exam=${e.examId}`} className="font-medium text-blue-700 underline">
                        {e.title}
                        {e.paper ? ` (${e.paper})` : ""}
                      </Link>
                    </th>
                    <td className="py-2 pr-4">{e.left}</td>
                    <td className="py-2 pr-4">{e.marked}</td>
                    <td className="py-2 pr-4">{e.onHold}</td>
                    <td className="py-2 pr-4">
                      <DeadlineLine deadline={e.deadline} overdue={e.overdue} now={now} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}

/** The marking part of the operations dashboard (public.marking_dashboard). */
async function MarkingOverview() {
  await requireStaff(["admin", "owner"]);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("marking_dashboard", {});
  const d = error ? null : parseMarkingDashboard(data);
  if (!d) {
    return (
      <div className="mb-6">
        <Card title="Marking">
          <p role="alert" className="text-sm text-red-700">The marking figures could not be loaded. Refresh the page to try again.</p>
        </Card>
      </div>
    );
  }
  return <MarkingDashboardView d={d} now={new Date()} />;
}

/** How many family emails (receipts and the like) are still to be sent; 0 when it cannot be read. */
async function familyNoticesWaiting(supabase: Awaited<ReturnType<typeof createClient>>): Promise<number> {
  const { data, error } = await supabase.rpc("script_family_notices_waiting", {});
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return 0;
  const a = data as { ok?: unknown; count?: unknown };
  return a.ok === true && typeof a.count === "number" ? a.count : 0;
}

export default function AdminDashboard() {
  return (
    <AppShell role="admin" title="Admin dashboard">
      <Suspense fallback={null}>
        <MissingPapers />
      </Suspense>
      <Suspense fallback={null}>
        <RolesUnchecked />
      </Suspense>
      <Suspense fallback={<p className="mb-6 text-sm text-slate-500">Loading the scripts figures...</p>}>
        <ScriptsOverview />
      </Suspense>
      <Suspense fallback={<p className="mb-6 text-sm text-slate-500">Loading the marking figures...</p>}>
        <MarkingOverview />
      </Suspense>
      <AccountsOverview accountsHref="/admin/accounts" roles={["admin", "owner"]} />
    </AppShell>
  );
}
