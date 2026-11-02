import { Suspense } from "react";
import { ExaminerPaperPage } from "@/components/ExaminerPaperPage";

export default function ExaminerPaper() {
  return (
    <Suspense fallback={<p className="p-6 text-sm text-slate-500">Loading paper…</p>}>
      <ExaminerPaperPage />
    </Suspense>
  );
}
