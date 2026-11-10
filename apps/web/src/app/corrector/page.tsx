import { AppShell, Card } from "@/components/AppShell";
import { GuardedPage } from "@/lib/staff-gate";

export default function CorrectorHome() {
  return (
    <GuardedPage roles={["corrector"]}>
      <AppShell role="corrector" title="Exam corrector">
        <Card>
          <p className="text-sm text-slate-600">Marking arrives in the next update</p>
        </Card>
      </AppShell>
    </GuardedPage>
  );
}
