import Link from "next/link";
import { Suspense } from "react";
import { AppShell, Card } from "@/components/AppShell";
import { ScriptList } from "@/components/scripts/ScriptList";
import { formatLondon } from "@/lib/money";
import { SCRIPT_STATES, STATE_LABEL, listArgs, parseFilters, parseScriptList } from "@/lib/script-repository";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

type Params = Record<string, string | string[] | undefined>;
const FIELD = "rounded border border-slate-300 bg-white px-2 py-1.5";

async function Body({ searchParams }: { searchParams: Promise<Params> }) {
  await requireStaff(["admin", "owner"]);
  const f = parseFilters(await searchParams);
  const supabase = await createClient();
  const [list, exams] = await Promise.all([
    supabase.rpc("scripts_list", listArgs(f)),
    supabase.from("exams").select("id, title, paper, starts_at").order("starts_at", { ascending: false }).limit(200),
  ]);
  if (exams.error) throw new Error("exams could not be loaded");
  const scripts = list.error ? null : parseScriptList(list.data);
  const filtered = Boolean(f.exam || f.source || f.state || f.late !== null);

  return (
    <div className="space-y-5">
      <Card title="Filter the scripts">
        <form method="get" action="/admin/scripts" aria-label="Filter the scripts" className="flex flex-wrap items-end gap-3 text-sm">
          <label className="flex flex-col gap-1">
            Exam
            <select name="exam" defaultValue={f.exam} className={`${FIELD} max-w-80`}>
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
            Source
            <select name="source" defaultValue={f.source ?? ""} className={FIELD}>
              <option value="">Home and centre</option>
              <option value="home">Home</option>
              <option value="centre">Centre</option>
            </select>
          </label>
          <label className="flex flex-col gap-1">
            State
            <select name="state" defaultValue={f.state ?? ""} className={FIELD}>
              <option value="">Any state</option>
              {SCRIPT_STATES.map((s) => (
                <option key={s} value={s}>
                  {STATE_LABEL[s]}
                </option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1">
            Late
            <select name="late" defaultValue={f.late === null ? "" : f.late ? "yes" : "no"} className={FIELD}>
              <option value="">Late or on time</option>
              <option value="yes">Late</option>
              <option value="no">On time</option>
            </select>
          </label>
          <button type="submit" className="rounded bg-blue-600 px-4 py-1.5 font-medium text-white hover:bg-blue-700">
            Apply filters
          </button>
          {filtered && (
            <Link href="/admin/scripts" className="py-1.5 text-blue-700 underline">
              Clear filters
            </Link>
          )}
        </form>
      </Card>
      <Card title="Scripts">
        <p className="mb-3 text-sm text-slate-600">
          Problems waiting for staff are in the{" "}
          <Link href="/admin/scripts/exceptions" className="text-blue-700 underline">
            exception queue
          </Link>
          .
        </p>
        {scripts ? (
          <ScriptList items={scripts.items} more={scripts.more} />
        ) : (
          <p role="alert" className="text-sm text-red-700">
            The scripts could not be loaded. Refresh the page to try again.
          </p>
        )}
      </Card>
    </div>
  );
}

export default function ScriptsPage({ searchParams }: { searchParams: Promise<Params> }) {
  return (
    <AppShell role="admin" title="Scripts">
      <Suspense fallback={<p className="text-sm text-slate-500">Loading the scripts...</p>}>
        <Body searchParams={searchParams} />
      </Suspense>
    </AppShell>
  );
}
