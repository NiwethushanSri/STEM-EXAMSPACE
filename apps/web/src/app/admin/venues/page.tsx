import { Suspense } from "react";
import { AppShell } from "@/components/AppShell";
import { VenuesManager } from "@/components/exams/VenuesManager";
import { loadAdminVenues } from "@/lib/exams-staff";

async function Body() {
  return <VenuesManager venues={await loadAdminVenues()} />;
}

export default function AdminVenues() {
  return (
    <AppShell role="admin" title="Venues">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading venues...</p>}>
        <Body />
      </Suspense>
    </AppShell>
  );
}
