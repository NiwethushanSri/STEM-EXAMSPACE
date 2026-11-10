import { Suspense } from "react";
import { AppShell } from "@/components/AppShell";
import { ExamsManager } from "@/components/exams/ExamsManager";
import { loadAdminExams } from "@/lib/exams-staff";

async function Body() {
  const { exams, subjects, venues, capped } = await loadAdminExams();
  return <ExamsManager exams={exams} subjects={subjects} venues={venues} capped={capped} />;
}

export default function AdminExams() {
  return (
    <AppShell role="admin" title="Exams">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading exams...</p>}>
        <Body />
      </Suspense>
    </AppShell>
  );
}
