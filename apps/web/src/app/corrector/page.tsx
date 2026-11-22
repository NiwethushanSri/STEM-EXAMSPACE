import Link from "next/link";
import { AppShell, Card } from "@/components/AppShell";
import { GuardedPage } from "@/lib/staff-gate";

export default function CorrectorHome() {
  return (
    <GuardedPage roles={["corrector"]}>
      <AppShell role="corrector" title="Exam corrector">
        <Card title="Marking">
          <p className="mb-3 text-sm text-slate-600">Your exams to mark and the scripts you are marking.</p>
          <Link href="/marking" className="font-medium text-blue-700 underline">
            Go to marking
          </Link>
        </Card>
      </AppShell>
    </GuardedPage>
  );
}
