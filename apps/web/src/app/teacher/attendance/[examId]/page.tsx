import { Suspense } from "react";
import { AppShell } from "@/components/AppShell";
import { RegisterView } from "@/components/attendance/Views";

async function Body({ params }: { params: Promise<{ examId: string }> }) {
  const { examId } = await params;
  return <RegisterView area="teacher" examId={examId} />;
}

export default function AttendanceRegister({ params }: { params: Promise<{ examId: string }> }) {
  return (
    <AppShell role="teacher" title="Attendance register">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading register...</p>}>
        <Body params={params} />
      </Suspense>
    </AppShell>
  );
}
