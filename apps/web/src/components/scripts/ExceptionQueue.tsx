"use client";

import { useEffect, useId, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Badge } from "@/components/AppShell";
import { PageViewer } from "@/components/scripts/PageViewer";
import { findCandidatesAction, resolveExceptionAction, saveHiddenAreasAction } from "@/app/admin/scripts/exceptions/actions";
import {
  KIND_LABEL,
  actionLabel,
  actionsFor,
  candidateLabel,
  copyPages,
  foundInWords,
  NAME_BOX_MESSAGE,
  needsNameCheck,
  noNameOffered,
  reasonProblem,
  reasonRequired,
  rejectsSubmission,
  resolutionLabel,
  resolvedNote,
  type CandidateOption,
  type QueueAction,
  type QueueArea,
  type QueueItem,
  type QueuePage,
  type ResolveInput,
} from "@/lib/exception-queue";
import { MAX_AREAS_PER_PAGE } from "@/lib/hidden-areas";
import { formatLondon } from "@/lib/money";

const BUTTON = "rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50";
const QUIET = "rounded border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";
const FIELD = "rounded border border-slate-300 px-2 py-1.5 text-sm";
/** A label around a visually hidden radio shows the radio's keyboard focus. */
const FOCUS_WITHIN = "focus-within:outline focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-blue-600";

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

const pageName = (p: QueuePage | null) => (p?.copyPage ? `Page ${p.copyPage}` : "A page with no code");
const versionText = (p: QueuePage) => (p.paperVersion ? `Version ${p.paperVersion} of the paper${p.paperCurrent === false ? " (replaced)" : ""}` : "No code, so no paper version");

/**
 * The exception queue: on the left the problems under the filters, newest first; on the right the one chosen, with
 * the full page picture (zoom, turn the view), what the server found in plain words, and the actions that fit it,
 * each with a reason box. "Assign" searches the exam's candidates by index number. A page whose name could not be
 * hidden gets "Hide the name": staff draw over the name on the full picture before accepting the page.
 */
export function ExceptionQueue({ items, more }: { items: QueueItem[]; more: boolean }) {
  const [selected, setSelected] = useState<string | null>(items[0]?.id ?? null);
  /** What the last resolution did: kept here, as the resolved problem leaves the list. */
  const [flash, setFlash] = useState<string | null>(null);
  /** Set when staff choose a problem in the list: its detail pane then takes the focus (a keyboard or screen reader user lands on it). */
  const [chosen, setChosen] = useState(false);
  const current = items.find((i) => i.id === selected) ?? items[0] ?? null;

  const done = (
    <div aria-live="polite">
      {flash && (
        <p data-testid="exception-done" className="mb-4 rounded border border-green-200 bg-green-50 p-3 text-sm text-green-900">
          {flash}
        </p>
      )}
    </div>
  );
  if (items.length === 0) {
    return (
      <>
        {done}
        <p className="rounded-lg border border-slate-200 bg-white p-5 text-sm text-slate-600">Nothing here. Every problem under these filters has been dealt with.</p>
      </>
    );
  }
  return (
    <>
      {done}
      <div className="grid gap-4 lg:grid-cols-[minmax(0,22rem)_minmax(0,1fr)]">
        <section aria-label="Problems" className="rounded-lg border border-slate-200 bg-white p-2 shadow-sm">
          <ul className="divide-y divide-slate-100" data-testid="exception-list">
            {items.map((i) => (
              <li key={i.id}>
                <button
                  type="button"
                  aria-current={current?.id === i.id ? "true" : undefined}
                  onClick={() => {
                  setSelected(i.id);
                  setChosen(true);
                }}
                  className={`block w-full rounded px-3 py-2 text-left text-sm ${current?.id === i.id ? "bg-blue-50 ring-1 ring-blue-600" : "hover:bg-slate-50"}`}
                >
                  <span className="flex items-center justify-between gap-2">
                    <span className="font-medium text-slate-900">{KIND_LABEL[i.kind]}</span>
                    <span className="text-xs text-slate-500">{formatLondon(i.createdAt)}</span>
                  </span>
                  <span className="block text-slate-700">{candidateLabel(i.booking ?? i.printedFor)}</span>
                  <span className="block text-xs text-slate-500">
                    {i.exam?.title ?? "Exam"}
                    {i.page?.copyPage ? ` · page ${i.page.copyPage}` : ""}
                    {i.upload ? ` · ${i.upload.source === "home" ? "home" : "centre"}` : ""}
                  </span>
                </button>
              </li>
            ))}
          </ul>
          {more && <p className="px-3 py-2 text-xs text-slate-500">Showing the 200 newest. Resolve these, or narrow the filters, to see the rest.</p>}
        </section>
        {current && <Detail key={current.id} item={current} onDone={setFlash} focusOnOpen={chosen} />}
      </div>
    </>
  );
}

function Detail({ item, onDone, focusOnOpen }: { item: QueueItem; onDone: (message: string) => void; focusOnOpen: boolean }) {
  const headingId = useId();
  const heading = useRef<HTMLHeadingElement>(null);
  useEffect(() => {
    if (focusOnOpen) heading.current?.focus();
  }, [focusOnOpen]);
  const words = foundInWords(item);
  const actions = actionsFor(item);
  const [action, setAction] = useState<QueueAction | null>(actions[0] ?? null);
  const home = item.upload?.source === "home";
  return (
    <section aria-labelledby={headingId} data-testid="exception-detail" className="space-y-4 rounded-lg border border-slate-200 bg-white p-5 shadow-sm">
      <div>
        <h2 id={headingId} ref={heading} tabIndex={-1} className="flex flex-wrap items-center gap-2 text-base font-semibold text-slate-900 focus:outline-none">
          {KIND_LABEL[item.kind]}
          {item.state === "resolved" ? <Badge tone="green">Resolved</Badge> : <Badge tone="amber">Open</Badge>}
        </h2>
        <dl className="mt-2 grid gap-x-4 gap-y-1 text-sm sm:grid-cols-[auto_1fr]">
          <dt className="text-slate-500">Exam</dt>
          <dd>
            {item.exam?.title ?? "Unknown"}
            {item.exam?.paper ? ` (${item.exam.paper})` : ""}
          </dd>
          <dt className="text-slate-500">Candidate</dt>
          <dd>{candidateLabel(item.booking)}</dd>
          {item.printedFor && item.printedFor.id !== item.booking?.id && (
            <>
              <dt className="text-slate-500">Printed for</dt>
              <dd>{candidateLabel(item.printedFor)}</dd>
            </>
          )}
          {item.script && (
            <>
              <dt className="text-slate-500">Script</dt>
              <dd>
                {item.script.number} · {item.script.source === "home" ? "home" : "centre"} · version {item.script.version}
                {item.script.late ? " · late" : ""}
              </dd>
            </>
          )}
          {item.upload && (
            <>
              <dt className="text-slate-500">From</dt>
              <dd>
                {home
                  ? `Handed in from home${item.upload.submissionSeq ? ` (submission ${item.upload.submissionSeq})` : ""}`
                  : `Scanned${item.upload.batchNumber ? ` (batch ${item.upload.batchNumber})` : ""}`}
                {item.page?.sourceIndex != null ? `, picture ${item.page.sourceIndex + 1} of the file` : ""}
              </dd>
            </>
          )}
          <dt className="text-slate-500">Raised</dt>
          <dd>{formatLondon(item.createdAt)}</dd>
        </dl>
      </div>

      <div>
        <h3 className="text-sm font-semibold text-slate-800">What the server found</h3>
        <ul className="mt-1 list-disc space-y-0.5 pl-5 text-sm text-slate-700" data-testid="exception-found">
          {words.map((w) => (
            <li key={w}>{w}</li>
          ))}
        </ul>
      </div>

      <Pictures item={item} drawing={action === "hide_areas"} />

      {item.state === "resolved" && item.resolved && (
        <p data-testid="exception-resolution" className="rounded border border-green-200 bg-green-50 p-3 text-sm text-green-900">
          {resolutionLabel(item.resolved.resolution)}
          {item.resolved.by ? ` by ${item.resolved.by}` : ""}
          {item.resolved.at ? ` on ${formatLondon(item.resolved.at)}` : ""}.{item.resolved.reason ? ` Reason: ${item.resolved.reason}` : ""}
        </p>
      )}

      {actions.length > 0 && (
        <fieldset className="space-y-3 border-t border-slate-100 pt-4">
          <legend className="text-sm font-semibold text-slate-800">Resolve</legend>
          <div className="flex flex-wrap gap-2" role="radiogroup" aria-label="What to do">
            {actions.map((a) => (
              <label
                key={a}
                className={`cursor-pointer rounded border px-3 py-1.5 text-sm ${FOCUS_WITHIN} ${action === a ? "border-blue-600 bg-blue-50 text-blue-900" : "border-slate-300 hover:bg-slate-50"}`}
              >
                <input type="radio" name={`action-${item.id}`} className="sr-only" checked={action === a} onChange={() => setAction(a)} />
                {actionLabel(a, item)}
              </label>
            ))}
          </div>
          {action === "hide_areas" && item.page ? (
            <AreaEditor key={item.page.id} page={item.page} />
          ) : action ? (
            <ActionForm key={action} item={item} action={action} onDone={onDone} />
          ) : null}
        </fieldset>
      )}
    </section>
  );
}

/** The page picture (and, for a duplicate, the page kept beside it); for mixed versions, the script's pages. */
function Pictures({ item, drawing }: { item: QueueItem; drawing: boolean }) {
  if (drawing) return null; // the area editor shows the page to draw on
  const p = item.page;
  return (
    <div className="space-y-3">
      {p && item.kind === "duplicate" && item.keptPage ? (
        <div className="grid gap-4 xl:grid-cols-2">
          <PageViewer path={p.fullPath} label={`This page (${pageName(p)})`} areas={p.areas} caption={<>This page: {versionText(p)}.</>} />
          <PageViewer path={item.keptPage.fullPath} label={`The page kept (${pageName(item.keptPage)})`} areas={item.keptPage.areas} caption={<>The page kept: {versionText(item.keptPage)}.</>} />
        </div>
      ) : p ? (
        <div className="max-w-xl">
          <PageViewer path={p.fullPath} label={pageName(p)} areas={p.areas} caption={<>{versionText(p)}. Full page picture: staff only.</>} />
        </div>
      ) : null}
      {item.linkedPages.length > 0 && (
        <div>
          <h3 className="text-sm font-semibold text-slate-800">The script shows now</h3>
          <ul className="mt-1 text-sm text-slate-700">
            {item.linkedPages.map((l) => (
              <li key={l.copyPage}>
                Page {l.copyPage}: {versionText(l.page)}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}

function ReasonBox({ value, onChange, required, familySees }: { value: string; onChange: (v: string) => void; required: boolean; familySees: boolean }) {
  const id = useId();
  return (
    <div className="space-y-1">
      <label htmlFor={id} className="block text-sm font-medium text-slate-800">
        {familySees ? "Reason (the family will see this)" : required ? "Reason (kept in the audit log)" : "Reason (optional)"}
      </label>
      <textarea id={id} value={value} onChange={(e) => onChange(e.target.value)} maxLength={300} rows={2} className={`${FIELD} w-full`} />
      <p className="text-xs text-slate-500">{value.trim().length}/300 characters{required ? ", at least 3" : ""}.</p>
    </div>
  );
}

function ActionForm({ item, action, onDone }: { item: QueueItem; action: QueueAction; onDone: (message: string) => void }) {
  const router = useRouter();
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<Note | null>(null);
  const missing = Array.isArray(item.details.pages) ? item.details.pages.filter((n): n is number => typeof n === "number") : [];
  const [pages, setPages] = useState<number[]>([]);
  const [choice, setChoice] = useState<{ bookingId: string; copyPage: number; occupied: boolean } | null>(() =>
    item.kind === "duplicate" && item.booking && item.page?.copyPage ? { bookingId: item.booking.id, copyPage: item.page.copyPage, occupied: true } : null,
  );
  const [replace, setReplace] = useState(false);
  const [noName, setNoName] = useState(false);
  // Confirming some pages, and assigning a page with no code, needs the name hidden first or "no name" ticked (R31).
  const nameCheck = (action === "confirm" || action === "assign") && needsNameCheck(item, action);
  // A page with a code carries the printed name box: no "no name" tick, staff draw a box over it (Ruling R40).
  const noNameAllowed = nameCheck && noNameOffered(item, action);
  const required = reasonRequired(action);
  const familySees = (action === "reject" && rejectsSubmission(item)) || action === "late_reject";

  async function submit() {
    const problem = reasonProblem(reason, required);
    if (problem) return setNote({ ok: false, text: problem });
    let input: ResolveInput;
    if (action === "assign") {
      if (!choice) return setNote({ ok: false, text: "Choose the candidate and the page first." });
      // A duplicate's "Use this page instead" replaces the page kept, which staff see beside it.
      const replacing = item.kind === "duplicate" || (choice.occupied && replace);
      if (choice.occupied && !replacing) return setNote({ ok: false, text: 'That page already holds a page. Tick "Replace the page that is there" to replace it.' });
      if (nameCheck && !noName) {
        return setNote({ ok: false, text: 'This page has no code, so hide the candidate\'s name first ("Hide the name"), or tick "There is no name on this page".' });
      }
      input = { action, exceptionId: item.id, bookingId: choice.bookingId, copyPage: choice.copyPage, reason, replace: replacing, noName: noNameAllowed && noName };
    } else if (action === "dismiss_missing") {
      if (pages.length === 0) return setNote({ ok: false, text: "Choose the pages that were left blank." });
      input = { action, exceptionId: item.id, pages, reason };
    } else if (action === "late_accept" || action === "late_reject") {
      if (!item.script) return;
      input = { action, scriptId: item.script.id, reason };
    } else if (action === "confirm") {
      if (nameCheck && !noNameAllowed) return setNote({ ok: false, text: NAME_BOX_MESSAGE });
      if (nameCheck && !noName) {
        return setNote({ ok: false, text: 'Hide the candidate\'s name first ("Hide the name"), or tick "There is no name on this page".' });
      }
      input = { action, exceptionId: item.id, reason, noName: noNameAllowed && noName };
    } else if (action === "blank" || action === "keep_existing" || action === "reject") {
      input = { action, exceptionId: item.id, reason };
    } else {
      return;
    }
    setBusy(true);
    setNote(null);
    const r = await resolveExceptionAction(input).catch(() => ({ ok: false as const, message: "Something went wrong. Please try again." }));
    setBusy(false);
    // An accepted page whose name the server did not hide waits for its marking picture to be checked (Task 8).
    const text = r.ok ? resolvedNote(item, action, r.message) : r.message;
    setNote({ ok: r.ok, text });
    if (r.ok) {
      onDone(`${KIND_LABEL[item.kind]}, ${candidateLabel(item.booking ?? item.printedFor)}: ${text}`);
      router.refresh();
    }
  }

  return (
    <div className="space-y-3" data-testid={`action-${action}`}>
      {action === "assign" && item.kind === "duplicate" && choice && (
        <p className="text-sm text-slate-700">
          This page becomes page {choice.copyPage} of {candidateLabel(item.booking)}&apos;s script, in place of the page kept.
        </p>
      )}
      {action === "assign" && item.kind !== "duplicate" && item.exam && (
        <AssignPicker
          examId={item.exam.id}
          suggestedPage={item.page?.copyPage ?? (typeof item.details.after_page === "number" ? item.details.after_page : null)}
          onChoose={(c) => {
            setChoice(c);
            setReplace(false);
          }}
        />
      )}
      {action === "assign" && item.kind !== "duplicate" && choice?.occupied && (
        <label className="flex items-start gap-2 text-sm text-slate-800">
          <input type="checkbox" className="mt-1" checked={replace} onChange={(e) => setReplace(e.target.checked)} />
          <span>
            Replace the page that is there
            <span className="block text-xs text-slate-500">The page it replaces stays as a duplicate for review.</span>
          </span>
        </label>
      )}
      {nameCheck && !noNameAllowed && (
        <p className="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900" data-testid="name-box-required">
          {NAME_BOX_MESSAGE}
        </p>
      )}
      {noNameAllowed && (
        <label className="flex items-start gap-2 text-sm text-slate-800">
          <input type="checkbox" className="mt-1" checked={noName} onChange={(e) => setNoName(e.target.checked)} />
          <span>
            There is no name on this page
            <span className="block text-xs text-slate-500">Otherwise hide the name first with &quot;Hide the name&quot;.</span>
          </span>
        </label>
      )}
      {action === "dismiss_missing" && (
        <fieldset className="space-y-1">
          <legend className="text-sm font-medium text-slate-800">Pages left blank</legend>
          <div className="flex flex-wrap gap-3">
            {missing.map((n) => (
              <label key={n} className="flex items-center gap-1.5 text-sm">
                <input type="checkbox" checked={pages.includes(n)} onChange={(e) => setPages((p) => (e.target.checked ? [...p, n].sort((a, b) => a - b) : p.filter((x) => x !== n)))} />
                Page {n}
              </label>
            ))}
          </div>
        </fieldset>
      )}
      {action === "reject" && rejectsSubmission(item) && (
        <p className="text-sm text-amber-900">
          The family&apos;s submission is rejected, with any later one that still counts this page, and they are emailed once with your reason. An
          earlier submission, if any, counts again; this page is taken out of the script.
        </p>
      )}
      {action === "late_reject" && (
        <p className="text-sm text-amber-900">
          The late upload is set aside and the family is emailed with your reason. Pages handed in on time are used; if there are none, the script is void and will not
          be marked.
        </p>
      )}
      {action === "reject" && !rejectsSubmission(item) && item.upload?.source === "home" && (
        <p className="text-sm text-slate-700">A later upload already replaced this page, so the family&apos;s submission stays as it is.</p>
      )}
      <ReasonBox value={reason} onChange={setReason} required={required} familySees={familySees} />
      <button type="button" className={BUTTON} disabled={busy} onClick={submit}>
        {busy ? "Saving..." : actionLabel(action, item)}
      </button>
      <NoteLine note={note} />
    </div>
  );
}

/** "Assign": find the exam's candidate by index number, then choose the page of their copy. */
function AssignPicker({
  examId,
  suggestedPage,
  onChoose,
}: {
  examId: string;
  suggestedPage: number | null;
  onChoose: (c: { bookingId: string; copyPage: number; occupied: boolean } | null) => void;
}) {
  const searchId = useId();
  const pageId = useId();
  const [query, setQuery] = useState("");
  const [busy, setBusy] = useState(false);
  const [found, setFound] = useState<CandidateOption[] | null>(null);
  const [note, setNote] = useState<Note | null>(null);
  const [bookingId, setBookingId] = useState<string | null>(null);
  const [copyPage, setCopyPage] = useState<number | null>(suggestedPage);
  const chosen = found?.find((c) => c.bookingId === bookingId) ?? null;

  function pick(b: string | null, p: number | null, list: CandidateOption[] | null = found) {
    setBookingId(b);
    setCopyPage(p);
    const c = list?.find((x) => x.bookingId === b) ?? null;
    onChoose(b && p ? { bookingId: b, copyPage: p, occupied: !!c?.pages.includes(p) } : null);
  }

  async function search() {
    setBusy(true);
    setNote(null);
    const r = await findCandidatesAction(examId, query).catch(() => ({ ok: false as const, message: "Something went wrong. Please try again." }));
    setBusy(false);
    if (!r.ok) {
      setFound(null);
      return setNote({ ok: false, text: r.message });
    }
    setFound(r.candidates);
    pick(null, copyPage, r.candidates);
    if (r.candidates.length === 0) setNote({ ok: false, text: "No candidate of this exam has that index number." });
  }

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-end gap-2">
        <label htmlFor={searchId} className="flex flex-col gap-1 text-sm font-medium text-slate-800">
          Candidate&apos;s index number
          <input
            id={searchId}
            type="search"
            value={query}
            maxLength={40}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                void search();
              }
            }}
            className={`${FIELD} w-56 font-normal`}
            placeholder="SE-2026-0142"
          />
        </label>
        <button type="button" className={QUIET} disabled={busy} onClick={search}>
          {busy ? "Searching..." : "Search"}
        </button>
      </div>
      <NoteLine note={note} />
      {found && found.length > 0 && (
        <fieldset className="space-y-1">
          <legend className="text-sm font-medium text-slate-800">Choose the candidate</legend>
          {found.map((c) => (
            <label key={c.bookingId} className="flex items-start gap-2 text-sm">
              <input type="radio" name="assign-candidate" className="mt-1" checked={bookingId === c.bookingId} onChange={() => pick(c.bookingId, copyPage)} />
              <span>
                {c.name} ({c.indexNumber ?? "no index number"}) · {c.sitting === "home" ? "at home" : "at the centre"}
                {c.attendance ? ` · ${c.attendance}` : ""}
                {c.status !== "paid" ? ` · ${c.status.replace("_", " ")}` : ""}
                <span className="block text-xs text-slate-500">
                  {c.scriptNumber ? `Script ${c.scriptNumber}: pages ${c.pages.length ? c.pages.join(", ") : "none yet"}` : "No script yet"}
                </span>
              </span>
            </label>
          ))}
        </fieldset>
      )}
      {chosen && (
        <label htmlFor={pageId} className="flex items-center gap-2 text-sm font-medium text-slate-800">
          Page of their copy
          <select
            id={pageId}
            value={copyPage ?? ""}
            onChange={(e) => pick(bookingId, e.target.value ? Number(e.target.value) : null)}
            className={`${FIELD} font-normal`}
          >
            <option value="">Choose</option>
            {copyPages(chosen.copyPages).map((n) => (
              <option key={n} value={n}>
                Page {n}
                {chosen.pages.includes(n) ? " (holds a page already)" : ""}
              </option>
            ))}
          </select>
        </label>
      )}
    </div>
  );
}

/** "Hide the name": draw over the candidate's name on the full page picture, then save the areas with a reason. */
function AreaEditor({ page }: { page: QueuePage }) {
  const router = useRouter();
  const [areas, setAreas] = useState<QueueArea[]>(page.areas);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<Note | null>(null);
  const dirty = JSON.stringify(areas) !== JSON.stringify(page.areas);

  async function save() {
    const problem = reasonProblem(reason, true);
    if (problem) return setNote({ ok: false, text: problem });
    setBusy(true);
    setNote(null);
    const r = await saveHiddenAreasAction(page.id, areas, reason).catch(() => ({ ok: false as const, message: "Something went wrong. Please try again." }));
    setBusy(false);
    setNote({ ok: r.ok, text: r.ok ? `${r.message} Now accept the page to have its marking picture made.` : r.message });
    if (r.ok) router.refresh();
  }

  return (
    <div className="space-y-3" data-testid="area-editor">
      <p className="text-sm text-slate-700">
        Drag over the candidate&apos;s name, and anything else that identifies them, on the full page. {areas.length}/{MAX_AREAS_PER_PAGE} areas.
      </p>
      <div className="max-w-xl">
        <PageViewer
          path={page.fullPath}
          label={`${pageName(page)}, drawing hidden areas`}
          areas={areas}
          onDraw={(a) => {
            if (areas.length >= MAX_AREAS_PER_PAGE) return setNote({ ok: false, text: `A page can have up to ${MAX_AREAS_PER_PAGE} hidden areas.` });
            setAreas((all) => [...all, a]);
          }}
        />
      </div>
      <ul className="divide-y divide-slate-100 text-sm" aria-label="Hidden areas of this page">
        {areas.length === 0 && <li className="py-1 text-slate-500">No hidden areas.</li>}
        {areas.map((a, i) => (
          <li key={i} className="flex items-center justify-between gap-2 py-1">
            <span>
              {Math.round(a.x * 100)}% across, {Math.round(a.y * 100)}% down, {Math.round(a.w * 100)}% wide, {Math.round(a.h * 100)}% high
            </span>
            <button
              type="button"
              aria-label={`Delete hidden area ${i + 1}`}
              onClick={() => setAreas((all) => all.filter((_, j) => j !== i))}
              className="rounded border border-red-300 px-2 py-0.5 text-xs font-medium text-red-700 hover:bg-red-50"
            >
              Delete
            </button>
          </li>
        ))}
      </ul>
      <ReasonBox value={reason} onChange={setReason} required familySees={false} />
      <button type="button" className={BUTTON} disabled={busy || !dirty} onClick={save}>
        {busy ? "Saving..." : "Save hidden areas"}
      </button>
      <NoteLine note={note} />
    </div>
  );
}
