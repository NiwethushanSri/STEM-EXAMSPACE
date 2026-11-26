import { Suspense } from "react";
import { AppShell } from "@/components/AppShell";
import { FamilyHomeBody } from "@/components/family/FamilyHomeBody";

export default function StudentHome() {
  return (
    <AppShell role="student" title="Your exams">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading...</p>}>
        <FamilyHomeBody role="student" />
      </Suspense>
    </AppShell>
  );
}
