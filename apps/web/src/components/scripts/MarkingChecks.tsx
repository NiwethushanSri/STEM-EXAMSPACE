"use client";

import { useEffect, useId, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { PageViewer } from "@/components/scripts/PageViewer";
import { markingCheckedAction, markingNameShowsAction } from "@/app/admin/scripts/exceptions/actions";
import { candidateLabel, checkTitle, reasonProblem, type MarkingCheckItem } from "@/lib/exception-queue";

const BUTTON = "rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50";
const QUIET = "rounded border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";
const FIELD = "rounded border border-slate-300 px-2 py-1.5 text-sm";
const FAILED = "Something went wrong. Please try again.";

type Note = { ok: boolean; text: string };

function NoteLine({ note }: { note: Note | null }) {
  return (
    <>
      <div aria-live="polite">{note?.ok && <p className="text-sm text-green-800">{note.text}</p>}</div>
      {note && !note.ok && (
        <p role="alert" className="text-sm text-red-700">
          {note.text}
        </p>
      )}
    </>
  );
}

/**
 * The marking pictures staff check before their page counts (Phase 3A Task 8): pages staff accepted, whose marking
 * picture was made afterwards. On the left the pages, oldest first; on the right the one chosen, with its full picture
 * beside its marking picture (what markers see). "The name is hidden" lets the page count; "A name still shows", with
 * a reason, sends it back to "Hide the name" under Problems.
 */
export function MarkingChecks({ items }: { items: MarkingCheckItem[] }) {
  const [selected, setSelected] = useState<string | null>(items[0]?.pageId ?? null);
  /** What the last check did: kept here, as the page leaves the list. */
  const [flash, setFlash] = useState<string | null>(null);
  /** Set when staff choose a page in the list: its detail then takes the focus. */
  const [chosen, setChosen] = useState(false);
  const current = items.find((i) => i.pageId === selected) ?? items[0] ?? null;

  const done = (
    <div aria-live="polite">
      {flash && (
        <p data-testid="check-done" className="mb-4 rounded border border-green-200 bg-green-50 p-3 text-sm text-green-900">
          {flash}
        </p>
      )}
    </div>
  );
  if (items.length === 0) {
    return (
      <>
        {done}
        <p className="rounded-lg border border-slate-200 bg-white p-5 text-sm text-slate-600">No marking pictures wait to be checked.</p>
      </>
    );
  }
  return (
    <>
      {done}
      <div className="grid gap-4 lg:grid-cols-[minmax(0,22rem)_minmax(0,1fr)]">
        <section aria-label="Marking pictures to check" className="rounded-lg border border-slate-200 bg-white p-2 shadow-sm">
          <ul className="divide-y divide-slate-100" data-testid="check-list">
            {items.map((i) => (
              <li key={i.pageId}>
                <button
                  type="button"
                  aria-current={current?.pageId === i.pageId ? "true" : undefined}
                  onClick={() => {
                    setSelected(i.pageId);
                    setChosen(true);
                  }}
                  className={`block w-full rounded px-3 py-2 text-left text-sm ${current?.pageId === i.pageId ? "bg-blue-50 ring-1 ring-blue-600" : "hover:bg-slate-50"}`}
                >
                  <span className="block font-medium text-slate-900">{checkTitle(i)}</span>
                  <span className="block text-slate-700">{candidateLabel(i.booking)}</span>
                </button>
              </li>
            ))}
          </ul>
          {items.length >= 200 && <p className="px-3 py-2 text-xs text-slate-500">Showing the 200 oldest. Check these to see the rest.</p>}
        </section>
        {current && <Check key={`${current.pageId}|${current.markingPath}`} item={current} onDone={setFlash} focusOnOpen={chosen} />}
      </div>
    </>
  );
}

function Check({ item, onDone, focusOnOpen }: { item: MarkingCheckItem; onDone: (message: string) => void; focusOnOpen: boolean }) {
  const router = useRouter();
  const headingId = useId();
  const reasonId = useId();
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    if (focusOnOpen) heading.current?.focus();
  }, [focusOnOpen]);
  const [reason, setReason] = useState("");
  /** Which of the two answers is being saved. */
  const [busy, setBusy] = useState<"hidden" | "shows" | null>(null);
  const [note, setNote] = useState<Note | null>(null);
  const title = checkTitle(item);

  async function run(nameShows: boolean) {
    if (nameShows) {
      const problem = reasonProblem(reason, true);
      if (problem) return setNote({ ok: false, text: problem });
    }
    setBusy(nameShows ? "shows" : "hidden");
    setNote(null);
    const r = await (nameShows ? markingNameShowsAction(item.pageId, reason) : markingCheckedAction(item.pageId, item.markingPath)).catch(() => ({
      ok: false as const,
      message: FAILED,
    }));
    setBusy(null);
    setNote({ ok: r.ok, text: r.message });
    if (r.ok) {
      onDone(`${title}, ${candidateLabel(item.booking)}: ${r.message}`);
      router.refresh();
    }
  }

  return (
    <section aria-labelledby={headingId} data-testid="check-detail" className="space-y-4 rounded-lg border border-slate-200 bg-white p-5 shadow-sm">
      <div>
        <h2 id={headingId} ref={heading} tabIndex={-1} className="text-base font-semibold text-slate-900 focus:outline-none">
          {title}
        </h2>
        <dl className="mt-2 grid gap-x-4 gap-y-1 text-sm sm:grid-cols-[auto_1fr]">
          <dt className="text-slate-500">Candidate</dt>
          <dd>{candidateLabel(item.booking)}</dd>
        </dl>
        <p className="mt-2 text-sm text-slate-700">
          Staff accepted this page, and its marking picture was made afterwards. Markers see only the marking picture: look over all of it, margins too, for a name or
          anything else that tells whose script it is.
        </p>
      </div>
      <div className="grid gap-4 xl:grid-cols-2">
        <PageViewer path={item.fullPath} label={`${title}, full picture`} caption={<>Full picture: staff only.</>} />
        <PageViewer path={item.markingPath} label={`${title}, marking picture`} caption={<>Marking picture: what markers see.</>} />
      </div>
      <div className="space-y-3 border-t border-slate-100 pt-4">
        <button type="button" className={BUTTON} disabled={busy !== null} onClick={() => run(false)}>
          {busy === "hidden" ? "Saving..." : "The name is hidden"}
        </button>
        <div className="space-y-1">
          <label htmlFor={reasonId} className="block text-sm font-medium text-slate-800">
            If a name still shows, say where (kept in the audit log)
          </label>
          <textarea id={reasonId} value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} rows={2} className={`${FIELD} w-full`} />
          <p className="text-xs text-slate-500">{reason.trim().length}/300 characters, at least 3.</p>
        </div>
        <button type="button" className={QUIET} disabled={busy !== null} onClick={() => run(true)}>
          {busy === "shows" ? "Saving..." : "A name still shows"}
        </button>
        <NoteLine note={note} />
      </div>
    </section>
  );
}
