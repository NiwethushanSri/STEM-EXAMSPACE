import Link from "next/link";
import { notFound } from "next/navigation";
import { Suspense } from "react";
import { AppShell } from "@/components/AppShell";
import { PrintButton, SendToParentButton } from "@/components/ResultsSheet";
import { ResultSheetPaper } from "@/components/ResultSheetPaper";
import { relationOf } from "@/lib/results";
import { children } from "@/lib/site-data";

export default function ResultsSheet({ params }: { params: Promise<{ id: string }> }) {
  // The shell reads the current URL, so the sheet streams in after the static part of the page.
  return (
    <Suspense fallback={<p className="p-6 text-sm text-slate-500">Loading sheet…</p>}>
      <Sheet params={params} />
    </Suspense>
  );
}

async function Sheet({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const child = children.find((c) => c.id === id);
  if (!child) notFound();

  return (
    <AppShell role="admin" title={`${relationOf(child)}'s results sheet`}>
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <Link href="/admin/results" className="text-sm text-blue-700 hover:underline">← All results sheets</Link>
        <div className="flex items-center gap-3">
          <PrintButton />
          <SendToParentButton parentEmail={child.parentEmail} />
        </div>
      </div>

      <ResultSheetPaper child={child} />
    </AppShell>
  );
}
