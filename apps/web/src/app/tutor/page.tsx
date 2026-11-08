import { AppShell, Card } from "@/components/AppShell";
import { GuardedPage } from "@/lib/staff-gate";

export default function TutorHome() {
  return (
    <GuardedPage roles={["tutor"]}>
      <AppShell role="tutor" title="Tutor">
        <Card>
          <p className="text-sm text-slate-600">Your tools arrive in a later update</p>
        </Card>
      </AppShell>
    </GuardedPage>
  );
}
