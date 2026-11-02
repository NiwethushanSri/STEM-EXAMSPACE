import { AppShell, Card, Stat, Badge } from "@/components/AppShell";
import { pendingApprovals, bookings, examinerProgress, accounts } from "@/lib/site-data";

export default function AdminDashboard() {
  const marked = examinerProgress.reduce((s, e) => s + e.marked, 0);
  const assigned = examinerProgress.reduce((s, e) => s + e.assigned, 0);
  return (
    <AppShell role="admin" title="Admin dashboard">
      <div className="grid gap-4 md:grid-cols-4">
        <Stat label="Accounts" value={accounts.length} />
        <Stat label="Awaiting approval" value={pendingApprovals.length} />
        <Stat label="Papers marked" value={`${marked} / ${assigned}`} />
        <Stat label="Open bookings" value={bookings.filter((b) => b.status !== "Paid").length} />
      </div>
      <div className="mt-6 grid gap-4 lg:grid-cols-2">
        <Card title="Pending student approvals">
          <ul className="divide-y divide-slate-100 text-sm">
            {pendingApprovals.map((p) => (
              <li key={p.name} className="flex items-center justify-between py-2.5">
                <span>
                  <span className="font-medium">{p.name}</span> · {p.school}
                </span>
                <span className="flex gap-2">
                  <button className="rounded bg-blue-600 px-3 py-1 text-xs text-white">Approve</button>
                  <button className="rounded border border-slate-300 px-3 py-1 text-xs">Reject</button>
                </span>
              </li>
            ))}
          </ul>
        </Card>
        <Card title="Examiner marking progress">
          <ul className="space-y-3 text-sm">
            {examinerProgress.map((e) => (
              <li key={e.name} className="flex items-center justify-between">
                <span>{e.name}</span>
                <span className="flex items-center gap-2">
                  {e.marked} / {e.assigned}
                  <Badge tone={e.accuracy === "In tolerance" ? "green" : "red"}>{e.accuracy}</Badge>
                </span>
              </li>
            ))}
          </ul>
        </Card>
      </div>
    </AppShell>
  );
}
