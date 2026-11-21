import { Suspense } from "react";
import Link from "next/link";
import { AppShell, Card } from "@/components/AppShell";
import { StructureEditor } from "@/components/marking/StructureEditor";
import { loadExamStructure } from "@/lib/exam-structure-server";
import { markSchemeBeginAction, markSchemeRemoveAction, markSchemeStoredAction, saveStructureAction } from "../actions";

async function Body({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { exam, view, problem } = await loadExamStructure(id, ["admin", "owner"]);
  return (
    <div className="space-y-5">
      <div>
        <Link href={`/admin/exams/${exam.id}`} className="text-sm text-blue-700 underline">
          Back to the exam
        </Link>
        <h2 className="mt-2 text-lg font-semibold text-slate-900">
          {exam.title}
          {exam.paper ? ` (${exam.paper})` : ""}
        </h2>
        <p className="text-sm text-slate-500">{exam.subject}</p>
      </div>
      {view ? (
        <StructureEditor
          examId={exam.id}
          initial={view}
          canChangeLocked
          actions={{ save: saveStructureAction, fileBegin: markSchemeBeginAction, fileStored: markSchemeStoredAction, fileRemove: markSchemeRemoveAction }}
        />
      ) : (
        <Card>
          <p role="alert" className="text-sm text-red-700">
            {problem}
          </p>
        </Card>
      )}
    </div>
  );
}

export default function AdminExamStructurePage({ params }: { params: Promise<{ id: string }> }) {
  return (
    <AppShell role="admin" title="Questions and mark scheme">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading questions...</p>}>
        <Body params={params} />
      </Suspense>
    </AppShell>
  );
}
