import { AppShell } from "@/components/AppShell";
import { ProgressReport } from "@/components/ProgressReport";

export default function ParentReport() {
  return (
    <AppShell role="parent" title="Progress report">
      <ProgressReport audience="parent" />
    </AppShell>
  );
}
