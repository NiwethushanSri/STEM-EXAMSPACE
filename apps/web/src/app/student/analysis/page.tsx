import { AppShell } from "@/components/AppShell";
import { AnalysisView } from "@/components/AnalysisView";

export default function StudentAnalysis() {
  return (
    <AppShell role="student" title="Performance analysis and forecast">
      <AnalysisView />
    </AppShell>
  );
}
