"use client";

import { useState, useTransition } from "react";
import { Card } from "@/components/AppShell";
import { custodyRecordAction } from "@/components/attendance/collection-actions";
import type { CustodyEvent, CustodyStep, StaffOption } from "@/lib/collection";
import { formatLondon } from "@/lib/money";

const STEP_LABEL: Record<CustodyStep, string> = {
  collected: "Collected",
  handed_over: "Handed over",
  scanned: "Scanned",
  archived: "Archived",
};
/** Steps staff record by hand: the scanner records "scanned" itself. */
const STEPS: CustodyStep[] = ["collected", "handed_over", "archived"];

const field = "rounded border border-slate-300 bg-white px-3 py-2 text-sm";

/** Who held the scripts, where, and when; with a form to record the next handover. */
export function CustodyPanel({ examId, centreId, events, staff }: { examId: string; centreId: string; events: CustodyEvent[]; staff: StaffOption[] }) {
  const [step, setStep] = useState<CustodyStep>("handed_over");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [location, setLocation] = useState("");
  const [note, setNote] = useState("");
  const [message, setMessage] = useState("");
  const [pending, start] = useTransition();
  const ready = location.trim() !== "" && (from !== "" || to !== "" || note.trim() !== "");

  function record() {
    setMessage("");
    start(async () => {
      try {
        const r = await custodyRecordAction(examId, centreId, { step, from, to, location, note });
        if (r.ok) {
          setLocation("");
          setNote("");
          setFrom("");
          setTo("");
          setMessage("Handover recorded.");
        } else setMessage(r.message);
      } catch {
        setMessage("Something went wrong. Please try again.");
      }
    });
  }

  const people = (
    <>
      <option value="">Nobody named</option>
      {staff.map((s) => (
        <option key={s.id} value={s.id}>
          {s.name} ({s.role})
        </option>
      ))}
    </>
  );

  return (
    <Card title="Custody">
      <div className="space-y-5">
        {events.length === 0 ? (
          <p className="text-sm text-slate-500">No handovers recorded yet.</p>
        ) : (
          <ol className="space-y-2 text-sm" data-testid="custody-list">
            {events.map((e) => (
              <li key={e.id} className="rounded border border-slate-200 p-3">
                <p className="font-medium text-slate-900">
                  {STEP_LABEL[e.step]} · {e.location}
                </p>
                <p className="text-slate-600">
                  {formatLondon(e.at)}
                  {e.fromName ? ` · from ${e.fromName}` : ""}
                  {e.toName ? ` · to ${e.toName}` : ""}
                  {e.manifest ? ` · ${e.manifest}` : ""}
                </p>
                {e.note && <p className="text-slate-700">{e.note}</p>}
                {e.byName && <p className="text-xs text-slate-500">Recorded by {e.byName}</p>}
              </li>
            ))}
          </ol>
        )}

        <form
          aria-label="Record handover"
          className="grid gap-3 sm:grid-cols-2"
          onSubmit={(e) => {
            e.preventDefault();
            if (ready) record();
          }}
        >
          <label className="flex flex-col gap-1 text-sm">
            Step
            <select value={step} onChange={(e) => setStep(e.target.value as CustodyStep)} className={field}>
              {STEPS.map((s) => (
                <option key={s} value={s}>
                  {STEP_LABEL[s]}
                </option>
              ))}
            </select>
          </label>
          <label className="flex flex-col gap-1 text-sm">
            Place
            <input value={location} onChange={(e) => setLocation(e.target.value)} maxLength={120} className={field} placeholder="Front desk" />
          </label>
          <label className="flex flex-col gap-1 text-sm">
            From
            <select value={from} onChange={(e) => setFrom(e.target.value)} className={field}>
              {people}
            </select>
          </label>
          <label className="flex flex-col gap-1 text-sm">
            To
            <select value={to} onChange={(e) => setTo(e.target.value)} className={field}>
              {people}
            </select>
          </label>
          <label className="flex flex-col gap-1 text-sm sm:col-span-2">
            Note (optional if someone is named)
            <textarea value={note} onChange={(e) => setNote(e.target.value)} maxLength={300} rows={2} className={field} />
          </label>
          <div className="flex flex-wrap items-center gap-3 sm:col-span-2">
            <button type="submit" disabled={pending || !ready} className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60">
              Record handover
            </button>
            {message && (
              <p role="status" className="text-sm text-slate-700">
                {message}
              </p>
            )}
          </div>
        </form>
      </div>
    </Card>
  );
}
