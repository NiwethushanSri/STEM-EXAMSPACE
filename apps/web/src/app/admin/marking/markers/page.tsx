import { Suspense } from "react";
import { AppShell } from "@/components/AppShell";
import { MarkersPanel, type MarkerRow, type SubjectRow } from "@/components/marking/MarkersPanel";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

type Raw = { ok?: boolean; subjects?: SubjectRow[]; markers?: MarkerRow[] };

async function Body() {
  await requireStaff(["admin", "owner"]);
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("markers_list");
  const list = data as Raw | null;
  if (error || !list || list.ok !== true || !Array.isArray(list.subjects) || !Array.isArray(list.markers)) {
    return (
      <p role="alert" className="text-sm text-red-700">
        The markers could not be loaded. Refresh the page to try again.
      </p>
    );
  }
  return <MarkersPanel subjects={list.subjects} markers={list.markers} />;
}

export default function MarkersPage() {
  return (
    <AppShell role="admin" title="Markers">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading the markers...</p>}>
        <Body />
      </Suspense>
    </AppShell>
  );
}
