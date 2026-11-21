import Link from "next/link";
import { Suspense } from "react";
import { AppShell, Card } from "@/components/AppShell";
import { UnsentDrafts } from "@/components/scripts/UnsentDrafts";
import { UNSENT_TEXT, parseUnsentDrafts } from "@/lib/home-drafts";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

type Params = Record<string, string | string[] | undefined>;

/** Answers families uploaded but never submitted (public.home_drafts_unsubmitted), for one exam or all. */
async function Body({ searchParams }: { searchParams: Promise<Params> }) {
  await requireStaff(["admin", "owner"]);
  const exam = (await searchParams).exam;
  const examId = typeof exam === "string" && isUuid(exam) ? exam : null;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("home_drafts_unsubmitted", examId ? { p_exam: examId } : {});
  const items = error ? null : parseUnsentDrafts(data);
  return (
    <Card title={UNSENT_TEXT.title}>
      <p className="mb-3 text-sm text-slate-600">{UNSENT_TEXT.intro}</p>
      {examId && (
        <p className="mb-3 text-sm">
          Showing one exam.{" "}
          <Link href="/admin/scripts/unsent" className="text-blue-700 underline">
            Show all exams
          </Link>
        </p>
      )}
      {items ? (
        <UnsentDrafts items={items} />
      ) : (
        <p role="alert" className="text-sm text-red-700">
          The list could not be loaded. Refresh the page to try again.
        </p>
      )}
    </Card>
  );
}

export default function UnsentPage({ searchParams }: { searchParams: Promise<Params> }) {
  return (
    <AppShell role="admin" title={UNSENT_TEXT.title}>
      <Suspense fallback={<p className="text-sm text-slate-500">Loading...</p>}>
        <Body searchParams={searchParams} />
      </Suspense>
    </AppShell>
  );
}
