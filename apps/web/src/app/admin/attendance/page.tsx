import { Suspense } from "react";
import { AppShell } from "@/components/AppShell";
import { PickerView } from "@/components/attendance/Views";

export default function Attendance() {
  return (
    <AppShell role="admin" title="Attendance">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading exams...</p>}>
        <PickerView area="admin" />
      </Suspense>
    </AppShell>
  );
}
