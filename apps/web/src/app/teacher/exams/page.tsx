import { Suspense } from "react";
import { AppShell } from "@/components/AppShell";
import { TeacherExams } from "@/components/exams/TeacherExams";
import { loadTeacherExams } from "@/lib/exams-staff";

async function Body() {
  const { exams, subjects, venues } = await loadTeacherExams();
  return <TeacherExams exams={exams} subjects={subjects} venues={venues} />;
}

export default function TeacherExamsPage() {
  return (
    <AppShell role="teacher" title="Exams">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading exams...</p>}>
        <Body />
      </Suspense>
    </AppShell>
  );
}
