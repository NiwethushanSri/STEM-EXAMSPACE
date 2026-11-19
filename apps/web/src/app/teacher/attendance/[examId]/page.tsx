import { Suspense } from "react";
import { AppShell } from "@/components/AppShell";
import { RegisterView } from "@/components/attendance/Views";

async function Body({ params, searchParams }: { params: Promise<{ examId: string }>; searchParams: Promise<{ centre?: string | string[] }> }) {
  const { examId } = await params;
  const { centre } = await searchParams;
  return <RegisterView area="teacher" examId={examId} centreId={typeof centre === "string" ? centre : null} />;
}

export default function AttendanceRegister({
  params,
  searchParams,
}: {
  params: Promise<{ examId: string }>;
  searchParams: Promise<{ centre?: string | string[] }>;
}) {
  return (
    <AppShell role="teacher" title="Attendance register">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading register...</p>}>
        <Body params={params} searchParams={searchParams} />
      </Suspense>
    </AppShell>
  );
}
