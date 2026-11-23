"use client";

import { useId, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { acceptDraftAction } from "@/app/admin/scripts/unsent/actions";
import { UNSENT_TEXT, acceptReasonProblem, draftCandidate, replacesNote, type UnsentDraft } from "@/lib/home-drafts";
import { formatLondon } from "@/lib/money";

const BUTTON = "rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50";

/** One family's uploaded but unsent answers, with "Submit for the family" (a reason is needed and kept). */
function Row({ d }: { d: UnsentDraft }) {
  const router = useRouter();
  const id = useId();
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);
  const who = draftCandidate(d);

  async function accept() {
    const problem = acceptReasonProblem(reason);
    if (problem) return setNote({ ok: false, text: problem });
    setBusy(true);
    setNote(null);
    const r = await acceptDraftAction(d.submissionId, reason).catch(() => ({ ok: false, message: "Something went wrong. Please try again." }));
    setBusy(false);
    setNote({ ok: r.ok, text: r.message });
    if (r.ok) router.refresh();
  }

  return (
    <li data-testid="unsent-draft" className="space-y-2 py-4">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <p className="font-medium text-slate-900">{who}</p>
        <p className={`text-sm ${d.late ? "text-amber-900" : "text-slate-600"}`}>{d.late ? UNSENT_TEXT.late : UNSENT_TEXT.onTime}</p>
      </div>
      <p className="text-sm text-slate-700">
        {d.exam ? (
          <>
            <Link href={`/admin/exams/${d.exam.id}`} className="text-blue-700 underline">
              {d.exam.title}
              {d.exam.paper ? ` (${d.exam.paper})` : ""}
            </Link>
            , {formatLondon(d.exam.startsAt)}.{" "}
          </>
        ) : null}
        {d.files} {d.files === 1 ? "file" : "files"} uploaded{d.lastFileAt ? `, the last on ${formatLondon(d.lastFileAt)}` : ""}.
      </p>
      {replacesNote(d) && (
        <p data-testid="unsent-replaces" className="text-sm font-medium text-amber-900">
          {replacesNote(d)}
        </p>
      )}
      <div className="flex flex-wrap items-end gap-2">
        <label htmlFor={id} className="flex min-w-64 flex-1 flex-col gap-1 text-sm text-slate-700">
          {UNSENT_TEXT.reason}
          <input id={id} type="text" value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)}
            className="rounded border border-slate-300 bg-white px-2 py-1.5" />
        </label>
        <button type="button" className={BUTTON} disabled={busy} onClick={() => void accept()}>
          {UNSENT_TEXT.accept}
          <span className="sr-only">: {who}</span>
        </button>
      </div>
      {note && (
        <p role={note.ok ? "status" : "alert"} className={`text-sm ${note.ok ? "text-green-800" : "text-red-700"}`}>
          {note.text}
        </p>
      )}
    </li>
  );
}

export function UnsentDrafts({ items }: { items: UnsentDraft[] }) {
  if (items.length === 0) return <p className="text-sm text-slate-600">{UNSENT_TEXT.none}</p>;
  return (
    <ul className="divide-y divide-slate-100" data-testid="unsent-drafts">
      {items.map((d) => (
        <Row key={d.submissionId} d={d} />
      ))}
    </ul>
  );
}
