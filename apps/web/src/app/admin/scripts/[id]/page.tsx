import Link from "next/link";
import { notFound } from "next/navigation";
import { Suspense } from "react";
import { AppShell } from "@/components/AppShell";
import { ScriptDetailView } from "@/components/scripts/ScriptDetail";
import { parseScriptDetail } from "@/lib/script-repository";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

async function Body({ params }: { params: Promise<{ id: string }> }) {
  await requireStaff(["admin", "owner"]);
  const { id } = await params;
  if (!isUuid(id)) notFound();
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("script_detail", { p_script: id });
  if (!error && data && typeof data === "object" && !Array.isArray(data) && (data as { code?: unknown }).code === "not_found") notFound();
  const detail = error ? null : parseScriptDetail(data);
  return (
    <div className="space-y-5">
      <Link href="/admin/scripts" className="text-sm text-blue-700 underline">
        Back to scripts
      </Link>
      {detail ? (
        <ScriptDetailView key={`${detail.script.id}|${detail.script.version}|${detail.script.state}`} detail={detail} />
      ) : (
        <p role="alert" className="text-sm text-red-700">
          The script could not be loaded. Refresh the page to try again.
        </p>
      )}
    </div>
  );
}

export default function ScriptPage({ params }: { params: Promise<{ id: string }> }) {
  return (
    <AppShell role="admin" title="Script">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading the script...</p>}>
        <Body params={params} />
      </Suspense>
    </AppShell>
  );
}
