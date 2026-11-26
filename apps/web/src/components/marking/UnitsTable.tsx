"use client";

import { useRouter } from "next/navigation";
import { useId, useState } from "react";
import { ReasonDialog } from "@/components/papers/ReasonDialog";
import {
  addSecond,
  assignSecond,
  assignSome,
  assignUnits,
  dropSecond,
  reassignUnits,
  takeBackSecond,
  takeBackUnits,
  type AllocationActionResult,
} from "@/app/admin/marking/actions";
import { firstShownText, unitStateLabel, ukDayTime, waitingLabel, type MarkingMode, type UnitRow } from "@/lib/marking-lists";
import { utcToLondonParts } from "@/lib/london-time";
import { checkStateText, secondMarkerText } from "@/lib/marking-review";

const BUTTON = "min-h-11 rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50";
const QUIET = "min-h-11 rounded border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";
const FIELD = "min-h-11 rounded border border-slate-300 bg-white px-2 py-1.5 text-sm";
const MAX = 200;

export type Choice = { id: string; label: string };
export type UnitFilters = { state: string | null; marker: string | null };

const STATE_FILTERS: Choice[] = [
  { id: "open", label: "Not taken" },
  { id: "taken", label: "Being marked" },
  { id: "submitted", label: "Submitted" },
  { id: "on_hold", label: "On hold" },
];

type Step =
  | { kind: "assign" }
  | { kind: "reassign" }
  | { kind: "take_back" }
  | { kind: "some"; n: number; groupId: string | null }
  // 3B: second marking of the ticked scripts.
  | { kind: "second_add" }
  | { kind: "second_drop" }
  | { kind: "second_assign" }
  | { kind: "second_take_back" };

/** The steps that give scripts to a marker, so ask which one. */
const TO_A_MARKER: Step["kind"][] = ["assign", "reassign", "some", "second_assign"];
const plural = (n: number) => `${n} ${n === 1 ? "script" : "scripts"}`;

const DIALOG_TITLE: Record<Step["kind"], (n: number, some: string) => string> = {
  assign: (n) => `Assign ${plural(n)}`,
  reassign: (n) => `Reassign ${plural(n)}`,
  take_back: (n) => `Take back ${plural(n)}`,
  some: (_n, some) => some,
  second_add: (n) => `Second-mark ${plural(n)}`,
  second_drop: (n) => `Release ${plural(n)} from second marking`,
  second_assign: (n) => `Assign second marking of ${plural(n)}`,
  second_take_back: (n) => `Take back second marking of ${plural(n)}`,
};
const CONFIRM_LABEL: Record<Step["kind"], string> = {
  assign: "Assign",
  reassign: "Reassign",
  take_back: "Take back",
  some: "Assign",
  second_add: "Second-mark these",
  second_drop: "Release",
  second_assign: "Assign",
  second_take_back: "Take back",
};

/** One exam's scripts (its pieces: whole scripts, or one per question group), filtered by state and marker, with tick
 * boxes for "Assign to…", "Take back" and "Reassign to…", and "Assign the next {n} to…". 3B: each script's check and
 * its second marker, and for the ticked scripts "Second-mark these", "Release from second marking", "Assign second
 * marking to…" and "Take back second marking". Each asks for a reason. The script number and index number only; no
 * candidate name. `markers`: the active markers approved for the subject. `more`: the list was cut short
 * (marking_units_list sends at most 2,000), and says so. */
export function UnitsTable({
  exam,
  exams,
  units,
  markers,
  filterMarkers,
  groups,
  filters,
  more = false,
}: {
  exam: { id: string; title: string; mode: MarkingMode };
  exams: Choice[];
  units: UnitRow[];
  markers: Choice[];
  filterMarkers: Choice[];
  groups: Choice[];
  filters: UnitFilters;
  more?: boolean;
}) {
  const router = useRouter();
  const [ticked, setTicked] = useState<Set<string>>(new Set());
  const [step, setStep] = useState<Step | null>(null);
  const [marker, setMarker] = useState("");
  const [count, setCount] = useState("10");
  const [group, setGroup] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<string | null>(null);
  const markerId = useId();
  const countId = useId();
  const groupId = useId();

  const byQuestion = exam.mode === "by_question";
  const visible = new Set(units.map((u) => u.unitId));
  const chosen = [...ticked].filter((id) => visible.has(id));
  const allTicked = units.length > 0 && chosen.length === units.length;
  const n = Number(count);
  const goodCount = Number.isInteger(n) && n >= 1 && n <= MAX;

  const toggle = (id: string) =>
    setTicked((t) => {
      const next = new Set(t);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  const open = (s: Step) => {
    setError(null);
    setMarker("");
    setStep(s);
  };
  const run = async (action: () => Promise<AllocationActionResult>) => {
    setBusy(true);
    const r = await action();
    setBusy(false);
    if (!r.ok) return setError(r.message);
    setStep(null);
    setTicked(new Set());
    setDone(r.message);
    router.refresh();
  };
  /** The dialog's confirm: a marker must be chosen where the action gives scripts to one. */
  const confirm = (reason: string) => {
    if (!step) return;
    if (TO_A_MARKER.includes(step.kind) && !marker) return setError("Choose a marker.");
    if (step.kind === "assign") return run(() => assignUnits(chosen, marker, reason));
    if (step.kind === "reassign") return run(() => reassignUnits(chosen, marker, reason));
    if (step.kind === "take_back") return run(() => takeBackUnits(chosen, reason));
    if (step.kind === "second_add") return run(() => addSecond(chosen, reason));
    if (step.kind === "second_drop") return run(() => dropSecond(chosen, reason));
    if (step.kind === "second_assign") return run(() => assignSecond(chosen, marker, reason));
    if (step.kind === "second_take_back") return run(() => takeBackSecond(chosen, reason));
    return run(() => assignSome(exam.id, step.groupId, marker, step.n, reason));
  };

  const markerPicker = (
    <label htmlFor={markerId} className="block text-sm">
      <span className="font-medium text-slate-700">Marker</span>
      <select id={markerId} value={marker} onChange={(e) => setMarker(e.target.value)} className={`${FIELD} mt-1 w-full`}>
        <option value="">Choose a marker</option>
        {markers.map((m) => (
          <option key={m.id} value={m.id}>
            {m.label}
          </option>
        ))}
      </select>
    </label>
  );

  return (
    <div className="space-y-4">
      <form method="get" action="/admin/marking" aria-label="Filter the scripts" className="flex flex-wrap items-end gap-3 text-sm">
        <label className="flex flex-col gap-1">
          Exam
          <select name="exam" defaultValue={exam.id} className={`${FIELD} max-w-80`}>
            {exams.map((e) => (
              <option key={e.id} value={e.id}>
                {e.label}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1">
          State
          <select name="state" defaultValue={filters.state ?? ""} className={FIELD}>
            <option value="">Any state</option>
            {STATE_FILTERS.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1">
          Marker
          <select name="marker" defaultValue={filters.marker ?? ""} className={FIELD}>
            <option value="">Any marker</option>
            {filterMarkers.map((m) => (
              <option key={m.id} value={m.id}>
                {m.label}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className={BUTTON}>
          Apply filters
        </button>
      </form>

      <div aria-live="polite">{done && <p className="text-sm text-green-800">{done}</p>}</div>

      <div className="flex flex-wrap items-center gap-2 rounded border border-slate-200 bg-slate-50 p-3 text-sm">
        <span className="mr-2 text-slate-700">{chosen.length === 0 ? "Tick scripts to assign, take back or reassign them." : `${chosen.length} ticked`}</span>
        <button type="button" className={QUIET} disabled={chosen.length === 0 || chosen.length > MAX} onClick={() => open({ kind: "assign" })}>
          Assign to…
        </button>
        <button type="button" className={QUIET} disabled={chosen.length === 0 || chosen.length > MAX} onClick={() => open({ kind: "take_back" })}>
          Take back
        </button>
        <button type="button" className={QUIET} disabled={chosen.length === 0 || chosen.length > MAX} onClick={() => open({ kind: "reassign" })}>
          Reassign to…
        </button>
        {chosen.length > MAX && <span className="text-red-700">Tick at most 200 scripts at a time.</span>}
      </div>

      <div className="flex flex-wrap items-center gap-2 rounded border border-slate-200 bg-slate-50 p-3 text-sm">
        <span className="mr-2 text-slate-700">Second marking of the ticked scripts:</span>
        <button type="button" className={QUIET} disabled={chosen.length === 0 || chosen.length > MAX} onClick={() => open({ kind: "second_add" })}>
          Second-mark these
        </button>
        <button type="button" className={QUIET} disabled={chosen.length === 0 || chosen.length > MAX} onClick={() => open({ kind: "second_drop" })}>
          Release from second marking
        </button>
        <button type="button" className={QUIET} disabled={chosen.length === 0 || chosen.length > MAX} onClick={() => open({ kind: "second_assign" })}>
          Assign second marking to…
        </button>
        <button type="button" className={QUIET} disabled={chosen.length === 0 || chosen.length > MAX} onClick={() => open({ kind: "second_take_back" })}>
          Take back second marking
        </button>
      </div>

      <div className="flex flex-wrap items-end gap-3 text-sm">
        <label htmlFor={countId} className="flex flex-col gap-1">
          How many
          <input id={countId} type="number" min={1} max={MAX} value={count} onChange={(e) => setCount(e.target.value)} className={`${FIELD} w-24`} />
        </label>
        {byQuestion && (
          <label htmlFor={groupId} className="flex flex-col gap-1">
            Question group
            <select id={groupId} value={group} onChange={(e) => setGroup(e.target.value)} className={FIELD}>
              <option value="">Any group</option>
              {groups.map((g) => (
                <option key={g.id} value={g.id}>
                  {g.label}
                </option>
              ))}
            </select>
          </label>
        )}
        <button type="button" className={QUIET} disabled={!goodCount} onClick={() => open({ kind: "some", n, groupId: group || null })}>
          {`Assign the next ${goodCount ? n : "n"} to…`}
        </button>
        {!goodCount && <span className="text-red-700">Choose a number from 1 to 200.</span>}
      </div>

      {units.length === 0 ? (
        <p className="text-sm text-slate-600">No script matches these filters.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="py-2 pr-3 font-medium">
                  <input
                    type="checkbox"
                    aria-label="Tick every script shown"
                    checked={allTicked}
                    onChange={() => setTicked(allTicked ? new Set() : new Set(units.map((u) => u.unitId)))}
                    className="h-5 w-5"
                  />
                </th>
                <th className="py-2 pr-4 font-medium">Script</th>
                <th className="py-2 pr-4 font-medium">Index number</th>
                {byQuestion && <th className="py-2 pr-4 font-medium">Questions</th>}
                <th className="py-2 pr-4 font-medium">State</th>
                <th className="py-2 pr-4 font-medium">Marker</th>
                <th className="py-2 pr-4 font-medium">Hold</th>
                <th className="py-2 pr-4 font-medium">Last saved</th>
                <th className="py-2 pr-4 font-medium">Total</th>
                <th className="py-2 pr-4 font-medium">Held back by</th>
                <th className="py-2 pr-4 font-medium">Check</th>
                <th className="py-2 pr-4 font-medium">Second marker</th>
              </tr>
            </thead>
            <tbody>
              {units.map((u) => (
                <tr key={u.unitId} data-testid="marking-unit" className="border-b border-slate-100 last:border-0">
                  <td className="py-2.5 pr-3">
                    <input type="checkbox" aria-label={`Tick script ${u.scriptNumber}${u.groupLabel ? `, ${u.groupLabel}` : ""}`} checked={ticked.has(u.unitId)} onChange={() => toggle(u.unitId)} className="h-5 w-5" />
                  </td>
                  <td className="py-2.5 pr-4 font-medium">{u.scriptNumber}</td>
                  <td className="py-2.5 pr-4">{u.indexNumber ?? "—"}</td>
                  {byQuestion && <td className="py-2.5 pr-4">{u.groupLabel ?? "—"}</td>}
                  <td className="py-2.5 pr-4">{unitStateLabel(u)}</td>
                  <td className="py-2.5 pr-4">{u.markerName ?? "—"}</td>
                  <td className="py-2.5 pr-4">{u.how === "assigned" ? "Assigned" : u.how === "next" && u.holdUntil ? `Until ${utcToLondonParts(u.holdUntil).time}` : "—"}</td>
                  <td className="py-2.5 pr-4">{u.lastSavedAt ? ukDayTime(u.lastSavedAt) : "—"}</td>
                  <td className="py-2.5 pr-4">{u.state === "submitted" && u.total !== null ? u.total : "—"}</td>
                  <td className="py-2.5 pr-4">{waitingLabel(u.waiting) || "—"}</td>
                  <td className="py-2.5 pr-4">{checkStateText(u.checkState) || "—"}</td>
                  <td className="py-2.5 pr-4">{secondMarkerText(u.second) || "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
          {more && <p className="mt-2 text-sm text-slate-600">{firstShownText(units.length)} Filter to see the others.</p>}
        </div>
      )}

      {step && (
        <ReasonDialog
          title={DIALOG_TITLE[step.kind](chosen.length, step.kind === "some" ? `Assign the next ${step.n} of ${exam.title}` : "")}
          confirmLabel={CONFIRM_LABEL[step.kind]}
          busy={busy}
          error={error}
          onCancel={() => setStep(null)}
          onConfirm={confirm}
        >
          <div className="space-y-3 text-sm text-slate-700">
            {step.kind === "assign" && <p>The marker keeps them with no time limit. Scripts that cannot go to them are left as they are.</p>}
            {step.kind === "reassign" && <p>They are taken back and given to the marker you choose. Marks so far are set aside, not deleted.</p>}
            {step.kind === "take_back" && <p>Each marker&rsquo;s hold ends and their marking is set aside. Nothing is deleted. Submitted scripts are marked again.</p>}
            {step.kind === "some" && <p>The free scripts are chosen as Next script would choose them. Fewer are given when fewer are left.</p>}
            {step.kind === "second_add" && <p>Scripts whose first marking is submitted are marked again by a second marker, who does not see the first marks.</p>}
            {step.kind === "second_drop" && <p>Scripts waiting for a second marker are checked on their first marks. A second marking in progress is set aside.</p>}
            {step.kind === "second_assign" && <p>The marker keeps their second marking with no time limit. Scripts that cannot go to them are left as they are.</p>}
            {step.kind === "second_take_back" && <p>Each second marker&rsquo;s hold ends and their second marking is set aside. The first marking is left as it is. Nothing is deleted.</p>}
            {TO_A_MARKER.includes(step.kind) && markerPicker}
          </div>
        </ReasonDialog>
      )}
    </div>
  );
}
