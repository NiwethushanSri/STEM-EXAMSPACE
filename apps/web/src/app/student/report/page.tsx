import { AppShell } from "@/components/AppShell";
import { ProgressReport } from "@/components/ProgressReport";

export default function StudentReport() {
  return (
    <AppShell role="student" title="Progress report">
      <ProgressReport audience="student" />
    </AppShell>
  );
}
