import { Suspense } from "react";
import { AppShell, Card } from "@/components/AppShell";
import { AlertsList } from "@/components/marking/AlertsList";
import { MarkingProgress } from "@/components/marking/MarkingProgress";
import { MyWork } from "@/components/marking/MyWork";
import { MARKING_ROLES, parseAlerts, parseMyWork, parseProgress } from "@/lib/marking-lists";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

const LOADING = <p className="text-sm text-slate-500">Loading your marking...</p>;

/** The marker's own work, and for a lead marker the alerts and progress of the subjects they lead. Only what the
 * database functions give: script and index numbers, never a candidate's name. */
async function Body() {
  await requireStaff(MARKING_ROLES);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("marking_my_work", {});
  const work = error ? null : parseMyWork(data);
  if (!work) {
    return (
      <p role="alert" className="text-sm text-red-700">
        Your marking could not be loaded. Refresh the page to try again.
      </p>
    );
  }
  if (!work.approved) {
    return (
      <Card>
        <p className="text-sm text-slate-700">You are not approved to mark yet. Ask an admin.</p>
      </Card>
    );
  }
  const lead = work.leadSubjects.length > 0;
  const [alertsRes, progressRes] = lead ? await Promise.all([supabase.rpc("marking_alerts_list", {}), supabase.rpc("marking_progress", {})]) : [null, null];
  const alerts = alertsRes && !alertsRes.error ? parseAlerts(alertsRes.data) : null;
  const progress = progressRes && !progressRes.error ? parseProgress(progressRes.data) : null;
  const now = new Date().toISOString();
  return (
    <div className="space-y-6">
      <MyWork exams={work.exams} pieces={work.pieces} now={now} />
      {lead && (
        <>
          <Card title="Needs your attention">
            {alerts ? (
              <AlertsList alerts={alerts} />
            ) : (
              <p role="alert" className="text-sm text-red-700">
                The alerts could not be loaded. Refresh the page to try again.
              </p>
            )}
          </Card>
          <Card title="Progress">
            {progress ? (
              <MarkingProgress exams={progress} now={now} />
            ) : (
              <p role="alert" className="text-sm text-red-700">
                The progress could not be loaded. Refresh the page to try again.
              </p>
            )}
          </Card>
        </>
      )}
    </div>
  );
}

/** The staff shell with the signed-in role's menu (the layout only gates, Ruling R2). */
async function Shell() {
  const me = await requireStaff(MARKING_ROLES);
  return (
    <AppShell role={me.role} title="Marking">
      <Suspense fallback={LOADING}>
        <Body />
      </Suspense>
    </AppShell>
  );
}

export default function MarkingHome() {
  return (
    <Suspense fallback={<div className="p-6">{LOADING}</div>}>
      <Shell />
    </Suspense>
  );
}
