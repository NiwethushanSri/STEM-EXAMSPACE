"use client";

import { useId, useState, useTransition } from "react";
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

/** Approving, leads and conflicts for every corrector and teacher. Each action reads the reason box of its marker's card. */
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
        <MarkerCard key={m.id} marker={m} subjects={subjects} />
      ))}
    </div>
  );
}

function MarkerCard({ marker, subjects }: { marker: MarkerRow; subjects: SubjectRow[] }) {
  const router = useRouter();
  const reasonId = useId();
  const [reason, setReason] = useState("");
  const [note, setNote] = useState<Note | null>(null);
  const [pending, start] = useTransition();
  const [pick, setPick] = useState("");

  const approved = new Set(marker.subjects.map((s) => s.id));
  const nameOf = (id: number) => subjects.find((s) => s.id === id)?.name ?? `Subject ${id}`;
  const canApprove = marker.status === "active" ? subjects.filter((s) => !approved.has(s.id) && (marker.role === "corrector" || marker.teaches.includes(s.id))) : [];

  const run = (action: () => Promise<MarkerActionResult>, after?: () => void) =>
    start(async () => {
      const r = await action();
      setNote({ ok: r.ok, text: r.message });
      if (r.ok) {
        setReason("");
        after?.();
        router.refresh();
      }
    });

  return (
    <Card title={marker.name}>
      <div className="mb-3 flex flex-wrap items-center gap-2 text-sm">
        <Badge tone="slate">{marker.role === "teacher" ? "Teacher" : "Exam corrector"}</Badge>
        {marker.status === "suspended" && <Badge tone="red">Suspended</Badge>}
      </div>

      <div className="mb-4 max-w-md">
        <label htmlFor={reasonId} className="mb-1 block text-sm font-medium text-slate-800">
          Reason for the next change (3 to 300 characters)
        </label>
        <input id={reasonId} value={reason} maxLength={300} onChange={(e) => setReason(e.target.value)} className={`${FIELD} w-full`} />
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
                  <button type="button" className={QUIET} disabled={pending} onClick={() => run(() => setLeadMarkerAction(s.id, null, reason))}>
                    Remove lead marker
                  </button>
                ) : (
                  <button type="button" className={QUIET} disabled={pending || marker.status !== "active"} onClick={() => run(() => setLeadMarkerAction(s.id, marker.id, reason))}>
                    Make lead marker
                  </button>
                )}
                <button type="button" className={QUIET} disabled={pending} onClick={() => run(() => unapproveMarkerAction(marker.id, s.id, reason))}>
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
          <button type="button" className={BUTTON} disabled={pending || !pick} onClick={() => run(() => approveMarkerAction(marker.id, Number(pick), reason), () => setPick(""))}>
            Approve
          </button>
        </div>
      )}

      <Conflicts marker={marker} reason={reason} pending={pending} run={run} />

      <div aria-live="polite">{note?.ok && <p className="mt-3 text-sm text-green-800">{note.text}</p>}</div>
      {note && !note.ok && (
        <p role="alert" className="mt-3 text-sm text-red-700">
          {note.text}
        </p>
      )}
    </Card>
  );
}

const who = (c: { index_number: string | null; name: string | null }) => [c.name, c.index_number].filter(Boolean).join(" ") || "A candidate";

function Conflicts({
  marker,
  reason,
  pending,
  run,
}: {
  marker: MarkerRow;
  reason: string;
  pending: boolean;
  run: (action: () => Promise<MarkerActionResult>, after?: () => void) => void;
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
              <button type="button" className={`${QUIET} ml-auto`} disabled={pending} onClick={() => run(() => removeConflictAction(marker.id, c.student_id, reason))}>
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
          {chosen && (
            <>
              <label htmlFor={noteId} className="flex flex-col gap-1">
                Note (optional, up to 300 characters)
                <input id={noteId} value={conflictNote} maxLength={300} onChange={(e) => setConflictNote(e.target.value)} className={FIELD} />
              </label>
              <p className="text-slate-600">The reason is the box at the top of this marker&rsquo;s card.</p>
              <div className="flex gap-2">
                <button type="button" className={BUTTON} disabled={pending} onClick={() => run(() => setConflictAction(marker.id, chosen.id, conflictNote, reason), reset)}>
                  Add conflict
                </button>
                <button type="button" className={QUIET} onClick={reset}>
                  Cancel
                </button>
              </div>
            </>
          )}
          {!chosen && (
            <button type="button" className={QUIET} onClick={reset}>
              Cancel
            </button>
          )}
        </div>
      )}
    </div>
  );
}
