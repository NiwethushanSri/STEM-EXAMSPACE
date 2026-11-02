"use client";

import { useParams } from "next/navigation";
import { AppShell } from "@/components/AppShell";
import { PaperMarking } from "@/components/PaperMarking";

// Reads the paper ID from the URL. It runs inside a Suspense boundary on the route page.
export function ExaminerPaperPage() {
  const params = useParams<{ id: string }>();
  return (
    <AppShell role="examiner" title="Mark paper by question">
      <PaperMarking paperId={params.id} />
    </AppShell>
  );
}
