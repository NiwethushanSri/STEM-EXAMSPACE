import { AppShell, Card } from "@/components/AppShell";
import { GuardedPage } from "@/lib/staff-gate";

export default function TeacherHome() {
  return (
    <GuardedPage roles={["teacher"]}>
      <AppShell role="teacher" title="Teacher">
        <Card>
          <p className="text-sm text-slate-600">Your tools arrive in a later update</p>
        </Card>
      </AppShell>
    </GuardedPage>
  );
}
