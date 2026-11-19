import { Suspense } from "react";
import Link from "next/link";
import { AppShell, Card } from "@/components/AppShell";
import { AccountsOverview } from "@/components/accounts/AccountsSection";
import { loadExamsMissingPaper } from "@/lib/exams-staff";
import { missingPaperWarning } from "@/lib/print-pack";
import { formatLondon } from "@/lib/money";

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

export default function AdminDashboard() {
  return (
    <AppShell role="admin" title="Admin dashboard">
      <Suspense fallback={null}>
        <MissingPapers />
      </Suspense>
      <AccountsOverview accountsHref="/admin/accounts" roles={["admin", "owner"]} />
    </AppShell>
  );
}
