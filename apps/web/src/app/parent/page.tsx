import { Suspense } from "react";
import { AppShell } from "@/components/AppShell";
import { FamilyHomeBody } from "@/components/family/FamilyHomeBody";

export default function ParentHome() {
  return (
    <AppShell role="parent" title="Your children's exams">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading...</p>}>
        <FamilyHomeBody role="parent" />
      </Suspense>
    </AppShell>
  );
}
