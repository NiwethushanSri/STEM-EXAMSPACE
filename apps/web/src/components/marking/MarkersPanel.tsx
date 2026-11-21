"use client";

import { useId, useState, useTransition, type ReactNode } from "react";
import { useRouter } from "next/navigation";
import { Badge, Card } from "@/components/AppShell";
import {
  approveMarkerAction,
  findConflictCandidatesAction,
  removeConflictAction,
  setConflictAction,
  setLeadMarkerAction,
  unapproveMarkerAction,
  type CandidateHit,
  type MarkerActionResult,
} from "@/app/admin/marking/markers/actions";

export type SubjectRow = { id: number; name: string; lead_id: string | null };
export type ConflictRow = { student_id: string; index_number: string | null; name: string | null; note: string | null };
export type MarkerRow = {
  id: string;
  name: string;
  role: "corrector" | "teacher";
  status: "active" | "suspended";
  subjects: { id: number; lead: boolean }[];
  teaches: number[];
  conflicts: ConflictRow[];
};

const BUTTON = "rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50";
const QUIET = "rounded border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";
const FIELD = "rounded border border-slate-300 px-2 py-1.5 text-sm";

type Note = { ok: boolean; text: string };

/** Approving, leads and conflicts for every corrector and teacher. Each action opens its own small panel: what will happen, a reason, Confirm and Cancel. */
export function MarkersPanel({ subjects, markers }: { subjects: SubjectRow[]; markers: MarkerRow[] }) {
  if (markers.length === 0) {
    return (
      <Card title="Markers">
        <p className="text-sm text-slate-600">There are no correctors or teachers yet. Add them on the Accounts page, then approve them here.</p>
      </Card>
    );
  }
  return (
    <div className="space-y-5">
      <p className="max-w-3xl text-sm text-slate-600">
        A corrector or teacher can mark a subject once approved for it. A teacher can only be approved for a subject they teach. Each subject has one lead marker. Every change needs a reason and
        is written to the audit log.
      </p>
      {markers.map((m) => (
        <MarkerCard key={m.id} marker={m} subjects={subjects} markers={markers} />
      ))}
    </div>
  );
}

type Step =
  | { kind: "approve"; subject: number }
  | { kind: "unapprove"; subject: number }
  | { kind: "lead"; subject: number }
  | { kind: "unlead"; subject: number }
  | { kind: "conflict_remove"; student: string; who: string };

/** One action's panel: what will happen, its own reason box, Confirm and Cancel. A failed action keeps the panel open with the error. */
function ActionPanel({
  label,
  consequence,
  confirmLabel,
  onConfirm,
  onCancel,
  children,
}: {
  label: string;
  consequence?: string;
  confirmLabel: string;
  onConfirm: (reason: string) => Promise<MarkerActionResult>;
  onCancel: () => void;
  children?: ReactNode;
}) {
  const id = useId();
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  return (
    <div role="group" aria-label={label} className="mt-2 space-y-2 rounded border border-slate-200 bg-slate-50 p-3 text-sm">
      <p className="font-medium text-slate-800">{label}</p>
      {consequence && <p className="text-slate-700">{consequence}</p>}
      {children}
      <div className="max-w-md space-y-1">
        <label htmlFor={id} className="block font-medium text-slate-800">
          Reason (kept in the audit log)
        </label>
        <textarea id={id} value={reason} maxLength={300} rows={2} onChange={(e) => setReason(e.target.value)} className={`${FIELD} w-full`} />
        <p className="text-xs text-slate-500">{reason.trim().length}/300 characters, at least 3.</p>
      </div>
      {error && (
        <p role="alert" className="text-red-700">
          {error}
        </p>
      )}
      <div className="flex gap-2">
        <button
          type="button"
          className={BUTTON}
          disabled={pending}
          onClick={() =>
            start(async () => {
              const r = await onConfirm(reason);
              if (!r.ok) setError(r.message);
            })
          }
        >
          {pending ? "Saving..." : confirmLabel}
        </button>
        <button type="button" className={QUIET} disabled={pending} onClick={onCancel}>
          Cancel
        </button>
      </div>
    </div>
  );
}

const who = (c: { index_number: string | null; name: string | null }) => [c.name, c.index_number].filter(Boolean).join(" ") || "A candidate";

function MarkerCard({ marker, subjects, markers }: { marker: MarkerRow; subjects: SubjectRow[]; markers: MarkerRow[] }) {
  const router = useRouter();
  const [note, setNote] = useState<(Note & { notice?: boolean }) | null>(null);
  const [step, setStep] = useState<Step | null>(null);
  const [pick, setPick] = useState("");

  const approved = new Set(marker.subjects.map((s) => s.id));
  const nameOf = (id: number) => subjects.find((s) => s.id === id)?.name ?? `Subject ${id}`;
  const canApprove = marker.status === "active" ? subjects.filter((s) => !approved.has(s.id) && (marker.role === "corrector" || marker.teaches.includes(s.id))) : [];
  const leadName = (subject: number) => {
    const id = subjects.find((s) => s.id === subject)?.lead_id;
    return id && id !== marker.id ? (markers.find((m) => m.id === id)?.name ?? "The current lead marker") : null;
  };

  /** Runs an action with the panel's reason; success closes the panel and shows the result. */
  const confirm = async (action: () => Promise<MarkerActionResult>, after?: () => void): Promise<MarkerActionResult> => {
    const r = await action();
    if (r.ok) {
      setNote({ ok: true, text: r.message, notice: (r.alreadyMarked ?? 0) > 0 });
      setStep(null);
      after?.();
      router.refresh();
    }
    return r;
  };

  const panel = () => {
    if (!step) return null;
    const cancel = () => setStep(null);
    if (step.kind === "approve")
      return (
        <ActionPanel
          label={`Approve for ${nameOf(step.subject)}`}
          confirmLabel="Confirm"
          onCancel={cancel}
          onConfirm={(r) => confirm(() => approveMarkerAction(marker.id, step.subject, r), () => setPick(""))}
        />
      );
    if (step.kind === "unapprove")
      return (
        <ActionPanel
          label={`Remove approval for ${nameOf(step.subject)}`}
          consequence="Scripts they are marking in this subject go back for others to mark."
          confirmLabel="Confirm"
          onCancel={cancel}
          onConfirm={(r) => confirm(() => unapproveMarkerAction(marker.id, step.subject, r))}
        />
      );
    if (step.kind === "lead") {
      const earlier = leadName(step.subject);
      return (
        <ActionPanel
          label={`Make lead marker for ${nameOf(step.subject)}`}
          consequence={earlier ? `${earlier} stops being lead marker.` : undefined}
          confirmLabel="Confirm"
          onCancel={cancel}
          onConfirm={(r) => confirm(() => setLeadMarkerAction(step.subject, marker.id, r))}
        />
      );
    }
    if (step.kind === "unlead")
      return (
        <ActionPanel
          label={`Remove lead marker for ${nameOf(step.subject)}`}
          consequence={`${marker.name} stops being lead marker.`}
          confirmLabel="Confirm"
          onCancel={cancel}
          onConfirm={(r) => confirm(() => setLeadMarkerAction(step.subject, null, r))}
        />
      );
    return (
      <ActionPanel
        label={`Remove the conflict with ${step.who}`}
        confirmLabel="Confirm"
        onCancel={cancel}
        onConfirm={(r) => confirm(() => removeConflictAction(marker.id, step.student, r))}
      />
    );
  };

  return (
    <Card title={marker.name}>
      <div className="mb-3 flex flex-wrap items-center gap-2 text-sm">
        <Badge tone="slate">{marker.role === "teacher" ? "Teacher" : "Exam corrector"}</Badge>
        {marker.status === "suspended" && <Badge tone="red">Suspended</Badge>}
      </div>

      <h3 className="mb-2 text-sm font-semibold text-slate-800">Subjects</h3>
      {marker.subjects.length === 0 ? (
        <p className="mb-2 text-sm text-slate-600">Not approved to mark any subject.</p>
      ) : (
        <ul className="mb-3 divide-y divide-slate-100 text-sm">
          {marker.subjects.map((s) => (
            <li key={s.id} className="flex flex-wrap items-center gap-3 py-2">
              <span className="min-w-40 font-medium">{nameOf(s.id)}</span>
              {s.lead && <Badge tone="green">Lead marker</Badge>}
              <span className="ml-auto flex flex-wrap gap-2">
                {s.lead ? (
                  <button type="button" className={QUIET} onClick={() => setStep({ kind: "unlead", subject: s.id })}>
                    Remove lead marker
                  </button>
                ) : (
                  <button type="button" className={QUIET} disabled={marker.status !== "active"} onClick={() => setStep({ kind: "lead", subject: s.id })}>
                    Make lead marker
                  </button>
                )}
                <button type="button" className={QUIET} onClick={() => setStep({ kind: "unapprove", subject: s.id })}>
                  Remove approval
                </button>
              </span>
            </li>
          ))}
        </ul>
      )}
      {canApprove.length > 0 && (
        <div className="mb-4 flex flex-wrap items-end gap-2 text-sm">
          <label className="flex flex-col gap-1">
            Approve for a subject
            <select value={pick} onChange={(e) => setPick(e.target.value)} className={FIELD}>
              <option value="">Choose a subject</option>
              {canApprove.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </label>
          <button type="button" className={BUTTON} disabled={!pick} onClick={() => setStep({ kind: "approve", subject: Number(pick) })}>
            Approve
          </button>
        </div>
      )}

      <Conflicts marker={marker} onRemove={(c) => setStep({ kind: "conflict_remove", student: c.student_id, who: who(c) })} confirm={confirm} />

      {panel()}
      <div aria-live="polite">
        {note?.ok && <p className={`mt-3 text-sm ${note.notice ? "rounded border border-amber-200 bg-amber-50 p-3 text-amber-900" : "text-green-800"}`}>{note.text}</p>}
      </div>
    </Card>
  );
}

function Conflicts({
  marker,
  onRemove,
  confirm,
}: {
  marker: MarkerRow;
  onRemove: (c: ConflictRow) => void;
  confirm: (action: () => Promise<MarkerActionResult>, after?: () => void) => Promise<MarkerActionResult>;
}) {
  const [adding, setAdding] = useState(false);
  const [query, setQuery] = useState("");
  const [hits, setHits] = useState<CandidateHit[] | null>(null);
  const [chosen, setChosen] = useState<CandidateHit | null>(null);
  const [conflictNote, setConflictNote] = useState("");
  const [searchError, setSearchError] = useState<string | null>(null);
  const [searching, startSearch] = useTransition();
  const searchId = useId();
  const noteId = useId();

  const reset = () => {
    setAdding(false);
    setQuery("");
    setHits(null);
    setChosen(null);
    setConflictNote("");
    setSearchError(null);
  };
  const search = () =>
    startSearch(async () => {
      setChosen(null);
      const r = await findConflictCandidatesAction(query);
      if (r.ok) {
        setHits(r.candidates);
        setSearchError(null);
      } else {
        setHits(null);
        setSearchError(r.message);
      }
    });

  return (
    <div>
      <h3 className="mb-2 text-sm font-semibold text-slate-800">Declared conflicts</h3>
      {marker.conflicts.length === 0 ? (
        <p className="mb-2 text-sm text-slate-600">None. This marker may mark any candidate.</p>
      ) : (
        <ul className="mb-2 divide-y divide-slate-100 text-sm">
          {marker.conflicts.map((c) => (
            <li key={c.student_id} className="flex flex-wrap items-center gap-3 py-2">
              <span className="font-medium">{who(c)}</span>
              {c.note && <span className="text-slate-600">{c.note}</span>}
              <button type="button" className={`${QUIET} ml-auto`} onClick={() => onRemove(c)}>
                Remove
              </button>
            </li>
          ))}
        </ul>
      )}
      {!adding ? (
        <button type="button" className={QUIET} onClick={() => setAdding(true)}>
          Add a conflict
        </button>
      ) : (
        <div className="space-y-3 rounded border border-slate-200 p-3 text-sm">
          <div className="flex flex-wrap items-end gap-2">
            <label htmlFor={searchId} className="flex flex-col gap-1">
              Candidate&rsquo;s index number or name
              <input
                id={searchId}
                value={query}
                maxLength={40}
                onChange={(e) => setQuery(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "Enter") {
                    e.preventDefault();
                    search();
                  }
                }}
                className={FIELD}
              />
            </label>
            <button type="button" className={QUIET} disabled={searching} onClick={search}>
              Search
            </button>
          </div>
          {searchError && (
            <p role="alert" className="text-red-700">
              {searchError}
            </p>
          )}
          {hits && hits.length === 0 && <p className="text-slate-600">No candidate found.</p>}
          {hits && hits.length > 0 && (
            <ul aria-label="Candidates found" className="max-h-48 divide-y divide-slate-100 overflow-y-auto">
              {hits.map((h) => (
                <li key={h.id}>
                  <label className="flex cursor-pointer items-center gap-2 py-1.5">
                    <input type="radio" name={`candidate-${marker.id}`} checked={chosen?.id === h.id} onChange={() => setChosen(h)} />
                    {who({ index_number: h.indexNumber, name: h.name })}
                  </label>
                </li>
              ))}
            </ul>
          )}
          {chosen ? (
            <ActionPanel
              label={`Add a conflict with ${who({ index_number: chosen.indexNumber, name: chosen.name })}`}
              consequence="Scripts of this candidate they are marking go back for others to mark."
              confirmLabel="Add conflict"
              onCancel={reset}
              onConfirm={(r) => confirm(() => setConflictAction(marker.id, chosen.id, conflictNote, r), reset)}
            >
              <label htmlFor={noteId} className="flex flex-col gap-1">
                Note (optional, up to 300 characters)
                <input id={noteId} value={conflictNote} maxLength={300} onChange={(e) => setConflictNote(e.target.value)} className={FIELD} />
              </label>
            </ActionPanel>
          ) : (
            <button type="button" className={QUIET} onClick={reset}>
              Cancel
            </button>
          )}
        </div>
      )}
    </div>
  );
}
