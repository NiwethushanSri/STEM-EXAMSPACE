import Link from "next/link";
import { Suspense } from "react";
import { AppShell, Card } from "@/components/AppShell";
import { ExceptionQueue } from "@/components/scripts/ExceptionQueue";
import { EXCEPTION_KINDS, KIND_LABEL, parseQueue, type ExceptionKind } from "@/lib/exception-queue";
import { formatLondon } from "@/lib/money";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

type Params = { exam?: string | string[]; kind?: string | string[]; state?: string | string[] };
const first = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v) ?? "";
const isKind = (v: string): v is ExceptionKind => (EXCEPTION_KINDS as readonly string[]).includes(v);

async function Body({ searchParams }: { searchParams: Promise<Params> }) {
  await requireStaff(["admin", "owner"]);
  const p = await searchParams;
  const exam = isUuid(first(p.exam)) ? first(p.exam) : "";
  const rawKind = first(p.kind);
  const kind = isKind(rawKind) ? rawKind : null;
  const state = first(p.state) === "resolved" ? "resolved" : "open";
  const supabase = await createClient();
  const [list, exams] = await Promise.all([
    supabase.rpc("script_exceptions_list", { p_exam: exam || undefined, p_kind: kind ?? undefined, p_state: state }),
    supabase.from("exams").select("id, title, paper, starts_at").order("starts_at", { ascending: false }).limit(200),
  ]);
  if (exams.error) throw new Error("exams could not be loaded");
  const queue = list.error ? null : parseQueue(list.data);
  const filtered = Boolean(exam || kind || state !== "open");

  return (
    <div className="space-y-5">
      <Card title="Filter the queue">
        <form method="get" action="/admin/scripts/exceptions" aria-label="Filter the queue" className="flex flex-wrap items-end gap-3 text-sm">
          <label className="flex flex-col gap-1">
            Exam
            <select name="exam" defaultValue={exam} className="max-w-80 rounded border border-slate-300 bg-white px-2 py-1.5">
              <option value="">All exams</option>
              {(exams.data ?? []).map((e) => (
                <option key={e.id} value={e.id}>
                  {e.title}
                  {e.paper ? ` (${e.paper})` : ""} — {formatLondon(e.starts_at)}
                </option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1">
            Kind
            <select name="kind" defaultValue={kind ?? ""} className="rounded border border-slate-300 bg-white px-2 py-1.5">
              <option value="">All kinds</option>
              {EXCEPTION_KINDS.map((k) => (
                <option key={k} value={k}>
                  {KIND_LABEL[k]}
                </option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1">
            Show
            <select name="state" defaultValue={state} className="rounded border border-slate-300 bg-white px-2 py-1.5">
              <option value="open">Open</option>
              <option value="resolved">Resolved</option>
            </select>
          </label>
          <button type="submit" className="rounded bg-blue-600 px-4 py-1.5 font-medium text-white hover:bg-blue-700">
            Apply filters
          </button>
          {filtered && (
            <Link href="/admin/scripts/exceptions" className="py-1.5 text-blue-700 underline">
              Clear filters
            </Link>
          )}
        </form>
      </Card>
      {queue ? (
        <ExceptionQueue key={`${exam}|${kind ?? ""}|${state}`} items={queue.items} more={queue.more} />
      ) : (
        <p role="alert" className="text-sm text-red-700">
          The queue could not be loaded. Refresh the page to try again.
        </p>
      )}
    </div>
  );
}

export default function ExceptionQueuePage({ searchParams }: { searchParams: Promise<Params> }) {
  return (
    <AppShell role="admin" title="Script exceptions">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading the queue...</p>}>
        <Body searchParams={searchParams} />
      </Suspense>
    </AppShell>
  );
}
