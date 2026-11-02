import Link from "next/link";
import { AppShell, Card, Stat } from "@/components/AppShell";
import { responses } from "@/lib/mock-data";
import { examinerProgress } from "@/lib/site-data";

export default function ExaminerHome() {
  return (
    <AppShell role="examiner" title="Examiner worklist">
      <div className="grid gap-4 md:grid-cols-3">
        <Stat label="Responses in worklist" value={responses.length} />
        <Stat label="Papers marked this session" value={examinerProgress[0].marked} />
        <Stat label="Accuracy" value="In tolerance" />
      </div>
      <div className="mt-6">
        <Card title="Live marking · Physics">
          <ul className="divide-y divide-slate-100 text-sm">
            {responses.map((r) => (
              <li key={r.id} className="flex items-center justify-between py-2.5">
                <Link href="/examiner/marking" className="text-blue-700 underline">{r.id}</Link>
                <span className="text-slate-500">{r.status === "not_started" ? "Marking not started" : "In progress"}</span>
              </li>
            ))}
          </ul>
        </Card>
      </div>
    </AppShell>
  );
}
