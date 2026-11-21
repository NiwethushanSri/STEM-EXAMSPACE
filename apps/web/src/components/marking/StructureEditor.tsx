"use client";

import { useEffect, useState } from "react";
import { structureMessageFor } from "@stem/shared";
import { Card } from "@/components/AppShell";
import { ReasonDialog, REASON_MAX, REASON_MIN } from "@/components/papers/ReasonDialog";
import { storeFile } from "@/lib/home-upload";
import { uploadResumable } from "@/lib/resumable-upload";
import { createClient } from "@/lib/supabase/client";
import {
  ALTERNATIVES_MAX,
  GROUP_LABEL_MAX,
  GUIDANCE_MAX,
  LABEL_MAX,
  MARK_SCHEME_MAX_BYTES,
  MAX_MARK,
  OPTION_LABEL_MAX,
  POINT_LABEL_MAX,
  POINT_TEXT_MAX,
  addPart,
  addQuestion,
  depthOf,
  fullLabel,
  isParent,
  marksText,
  maxTotal,
  moveQuestion,
  newKey,
  removeQuestion,
  toPayload,
  totalOf,
  updateQuestion,
  validateStructure,
  type DraftPoint,
  type DraftQuestion,
  type FileBegun,
  type StructureDraft,
  type StructureError,
  type StructurePayload,
  type StructureResult,
  type StructureView,
} from "@/lib/exam-structure";

/** The area's server actions (admin, or a teacher of the subject). */
export type StructureActions = {
  save: (examId: string, structure: StructurePayload, reason?: string) => Promise<StructureResult>;
  fileBegin: (examId: string, bytes: number) => Promise<FileBegun>;
  fileStored: (examId: string, fileId: string) => Promise<{ ok: boolean; code?: string }>;
  fileRemove: (examId: string, fileId: string, reason: string) => Promise<StructureResult>;
};

const GENERIC = "Something went wrong. Please try again.";
const BUTTON = "rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50";
const QUIET = "rounded border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-800 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50";
const INPUT = "rounded border border-slate-300 bg-white px-2 py-1.5 text-sm text-slate-900 focus:border-blue-600 focus:outline-none focus:ring-2 focus:ring-blue-100 disabled:bg-slate-50 disabled:text-slate-500";
const FIELD_LABEL = "text-xs font-medium text-slate-600";
const INDENT = ["", "ml-6", "ml-12"];

type Note = { tone: "ok" | "error"; text: string };
type Upload = { file: File; fileId: string | null; path: string | null; state: "uploading" | "failed"; progress: number; error: string | null };

async function currentToken(): Promise<string | null> {
  return (await createClient().auth.getSession()).data.session?.access_token ?? null;
}

const toNumber = (s: string): number | null => (s.trim() === "" || !Number.isFinite(Number(s)) ? null : Number(s));

/**
 * The questions and mark scheme of an exam: one row per question or part (label, maximum, half marks, marked by
 * levels, pages, group, optional with…), "Add part" under a row, arrows to reorder, and a mark scheme panel per
 * question (marking points, acceptable alternatives, guidance); the optional questions, the question groups, the
 * paper total, and the mark scheme PDF. Once marking has started an admin may change only what the database allows,
 * with a reason; a teacher reads it. Everything is saved at once and checked again by the database.
 */
export function StructureEditor({
  examId,
  initial,
  canChangeLocked,
  actions,
}: {
  examId: string;
  initial: StructureView;
  /** An admin may still change a locked structure, with a reason; a teacher only reads it. */
  canChangeLocked: boolean;
  actions: StructureActions;
}) {
  const [view, setView] = useState(initial);
  const [draft, setDraft] = useState<StructureDraft>(initial.draft);
  const [dirty, setDirty] = useState(false);
  const [open, setOpen] = useState<Set<string>>(new Set());
  const [errors, setErrors] = useState<StructureError[] | null>(null);
  const [note, setNote] = useState<Note | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [upload, setUpload] = useState<Upload | null>(null);
  const [removing, setRemoving] = useState(false);
  const [removeError, setRemoveError] = useState<string | null>(null);
  const [fileNote, setFileNote] = useState<Note | null>(null);

  const locked = view.locked;
  const readOnly = locked && !canChangeLocked;
  const paper = view.paper;
  const pageChoices = paper
    ? [
        ...paper.answerPages.map((n) => ({ n, spare: false })),
        ...Array.from({ length: paper.sparePages }, (_, i) => ({ n: paper.pageCount + i + 1, spare: true })),
      ]
    : [];
  const choiceSet = new Set(pageChoices.map((c) => c.n));
  const total = maxTotal(draft);
  const rowErrors = (key: string) => (errors ?? []).filter((e) => e.key === key);

  /** The shared checks, and pages that are no longer answer or spare pages (the paper's roles changed since). */
  function check(d: StructureDraft): StructureError[] {
    const res = validateStructure(d, paper ?? { pageCount: 0, sparePages: 0 });
    const out = res.ok ? [] : [...res.errors];
    for (const q of d.questions) {
      const stale = q.pages.find((n) => !choiceSet.has(n));
      if (stale !== undefined && !out.some((e) => e.key === q.key && e.message.startsWith("Page "))) {
        out.push({ key: q.key, message: `Page ${stale} is not an answer page. Untick it.` });
      }
    }
    return out;
  }

  useEffect(() => {
    if (!dirty && !upload) return;
    const warn = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [dirty, upload]);

  function change(next: StructureDraft) {
    setDraft(next);
    setDirty(true);
    setNote(null);
    if (errors) setErrors(check(next));
  }
  const edit = (key: string, c: Partial<DraftQuestion>) => change(updateQuestion(draft, key, c));
  const toggle = (key: string) =>
    setOpen((s) => {
      const n = new Set(s);
      if (n.has(key)) n.delete(key);
      else n.add(key);
      return n;
    });

  async function save() {
    const problems = check(draft);
    if (problems.length > 0) {
      setErrors(problems);
      setNote({ tone: "error", text: "Some questions need fixing. They are marked below." });
      return;
    }
    setErrors([]);
    if (locked && (reason.trim().length < REASON_MIN || reason.trim().length > REASON_MAX)) {
      setNote({ tone: "error", text: "Give a reason of 3 to 300 characters." });
      return;
    }
    setBusy(true);
    setNote(null);
    const out = await actions.save(examId, toPayload(draft), locked ? reason.trim() : undefined).catch(() => ({ ok: false as const, message: GENERIC }));
    setBusy(false);
    if (!out.ok) {
      setNote({ tone: "error", text: out.message });
      return;
    }
    setDirty(false);
    setReason("");
    setErrors(null);
    if (!out.view) {
      setNote({ tone: "ok", text: "Saved. Refresh the page before you change anything else." });
      return;
    }
    const saved = out.view;
    setView((v) => ({ ...saved, markSchemeFile: v.markSchemeFile }));
    setDraft(saved.draft);
    setNote({ tone: "ok", text: out.message });
  }

  async function sendFile(u: Upload) {
    setUpload({ ...u, state: "uploading", progress: 0, error: null });
    let known = { uploadId: u.fileId, path: u.path };
    try {
      const done = await storeFile(
        known,
        {
          begin: async () => {
            const r = await actions.fileBegin(examId, u.file.size);
            if (!r.ok) throw new Error(r.code);
            return { uploadId: r.fileId, path: r.path };
          },
          upload: async (path) => {
            const token = await currentToken();
            if (!token) throw new Error("unauthenticated");
            await uploadResumable(u.file, {
              bucket: "mark-schemes",
              path,
              accessToken: token,
              getAccessToken: currentToken,
              contentType: "application/pdf",
              onProgress: (sent, all) => setUpload((x) => (x ? { ...x, progress: all ? sent / all : 0 } : x)),
            });
          },
          stored: (id) => actions.fileStored(examId, id),
        },
        (id, path) => {
          known = { uploadId: id, path };
          return true;
        },
      );
      if (done) setView((v) => ({ ...v, markSchemeFile: { id: done.uploadId, storagePath: done.path } }));
      setUpload(null);
      setFileNote({ tone: "ok", text: "The mark scheme PDF is attached." });
    } catch (e) {
      const code = e instanceof Error ? e.message : "internal";
      setUpload({
        ...u,
        fileId: known.uploadId,
        path: known.path,
        state: "failed",
        progress: 0,
        error: code === "unauthenticated" ? "Please sign in again." : structureMessageFor(code, "file"),
      });
    }
  }

  function chooseFile(file: File | undefined) {
    setFileNote(null);
    if (!file) return;
    if (file.type !== "application/pdf" && !file.name.toLowerCase().endsWith(".pdf")) {
      setFileNote({ tone: "error", text: "Choose a PDF file." });
      return;
    }
    if (file.size < 1) {
      setFileNote({ tone: "error", text: "This file is empty." });
      return;
    }
    if (file.size > MARK_SCHEME_MAX_BYTES) {
      setFileNote({ tone: "error", text: structureMessageFor("file_too_large", "file") });
      return;
    }
    void sendFile({ file, fileId: null, path: null, state: "uploading", progress: 0, error: null });
  }

  async function removeFile(why: string) {
    if (!view.markSchemeFile) return;
    setBusy(true);
    setRemoveError(null);
    const out = await actions.fileRemove(examId, view.markSchemeFile.id, why).catch(() => ({ ok: false as const, message: GENERIC }));
    setBusy(false);
    if (!out.ok) {
      setRemoveError(out.message);
      return;
    }
    setRemoving(false);
    setView((v) => ({ ...v, markSchemeFile: null }));
    setFileNote({ tone: "ok", text: out.message });
  }

  /** What a locked structure still lets an admin change on this row (the database decides again). */
  const fixed = (q: DraftQuestion) => locked && q.id !== null;
  const optionName = (key: string) => {
    const o = draft.optionGroups.find((x) => x.key === key);
    return o ? `${o.label.trim() || "Optional questions"} (answer ${o.choose})` : "";
  };

  /** One question or part. A render function, not a component, so its inputs keep focus while typing. */
  function questionRow(q: DraftQuestion) {
    const depth = depthOf(draft, q.key);
    const parent = isParent(draft, q.key);
    const name = fullLabel(draft, q.key);
    const top = q.parentKey === null;
    const errs = rowErrors(q.key);
    const panel = open.has(q.key);
    const siblings = draft.questions.filter((x) => x.parentKey === q.parentKey);
    const index = siblings.findIndex((x) => x.key === q.key);
    return (
      <li key={q.key} data-testid="structure-row" className={`${INDENT[Math.min(depth, 3) - 1] ?? ""} rounded-lg border ${errs.length ? "border-red-300" : "border-slate-200"} bg-white p-3`}>
        <div className="flex flex-wrap items-end gap-3">
          <label className="flex flex-col">
            <span className={FIELD_LABEL}>{top ? "Question" : "Part"}</span>
            <input
              value={q.label}
              onChange={(e) => edit(q.key, { label: e.target.value })}
              maxLength={LABEL_MAX}
              disabled={readOnly}
              aria-label={`Label of question ${name}`}
              className={`${INPUT} w-20`}
            />
          </label>
          <span className="pb-2 text-sm font-semibold text-slate-900">{name}</span>
          {parent ? (
            <span className="pb-2 text-sm text-slate-600">{marksText(totalOf(draft, q.key))} from its parts</span>
          ) : (
            <label className="flex flex-col">
              <span className={FIELD_LABEL}>Maximum</span>
              <input
                type="number"
                inputMode="decimal"
                min={q.markStep}
                max={MAX_MARK}
                step={q.markStep}
                value={q.maxMark ?? ""}
                onChange={(e) => edit(q.key, { maxMark: toNumber(e.target.value) })}
                disabled={readOnly}
                aria-label={`Maximum mark of question ${name}`}
                className={`${INPUT} w-24`}
              />
            </label>
          )}
          {!parent && (
            <label className="flex items-center gap-2 pb-2 text-sm text-slate-700">
              <input
                type="checkbox"
                checked={q.markStep === 0.5}
                onChange={(e) => edit(q.key, { markStep: e.target.checked ? 0.5 : 1 })}
                disabled={readOnly || fixed(q)}
              />
              Half marks
            </label>
          )}
          {!parent && (
            <label className="flex items-center gap-2 pb-2 text-sm text-slate-700">
              <input type="checkbox" checked={q.levels} onChange={(e) => edit(q.key, { levels: e.target.checked })} disabled={readOnly || fixed(q)} />
              Marked by levels
            </label>
          )}
          {top && (
            <label className="flex flex-col">
              <span className={FIELD_LABEL}>Group</span>
              <select
                value={q.groupKey ?? ""}
                onChange={(e) => edit(q.key, { groupKey: e.target.value || null })}
                disabled={readOnly || fixed(q) || draft.groups.length === 0}
                aria-label={`Group of question ${name}`}
                className={INPUT}
              >
                <option value="">No group</option>
                {draft.groups.map((g) => (
                  <option key={g.key} value={g.key}>
                    {g.label.trim() || "Unnamed group"}
                  </option>
                ))}
              </select>
            </label>
          )}
          {top && (
            <label className="flex flex-col">
              <span className={FIELD_LABEL}>Optional with…</span>
              <select
                value={q.optionGroupKey ?? ""}
                onChange={(e) => edit(q.key, { optionGroupKey: e.target.value || null })}
                disabled={readOnly || locked || draft.optionGroups.length === 0}
                aria-label={`Optional questions of question ${name}`}
                className={INPUT}
              >
                <option value="">Not optional</option>
                {draft.optionGroups.map((o) => (
                  <option key={o.key} value={o.key}>
                    {optionName(o.key)}
                  </option>
                ))}
              </select>
            </label>
          )}
        </div>

        <fieldset className="mt-3">
          <legend className={FIELD_LABEL}>Pages</legend>
          {pageChoices.length === 0 && q.pages.length === 0 ? (
            <p className="text-xs text-slate-500">Upload the question paper first to choose pages.</p>
          ) : (
            <div className="mt-1 flex flex-wrap gap-2">
              {[...pageChoices, ...q.pages.filter((n) => !choiceSet.has(n)).map((n) => ({ n, spare: false, stale: true }))].map(({ n, spare, ...c }) => (
                <label key={n} className="flex items-center gap-1.5 rounded border border-slate-200 px-2 py-1 text-sm text-slate-700">
                  <input
                    type="checkbox"
                    checked={q.pages.includes(n)}
                    disabled={readOnly}
                    onChange={(e) =>
                      edit(q.key, { pages: e.target.checked ? [...q.pages, n].sort((a, b) => a - b) : q.pages.filter((p) => p !== n) })
                    }
                  />
                  {"stale" in c ? `${n} (not an answer page)` : spare ? `${n} (spare)` : n}
                </label>
              ))}
            </div>
          )}
        </fieldset>

        <div className="mt-3 flex flex-wrap gap-2">
          <button type="button" onClick={() => toggle(q.key)} aria-expanded={panel} className={QUIET}>
            Mark scheme{q.points.length ? ` (${q.points.length} ${q.points.length === 1 ? "point" : "points"})` : ""}
          </button>
          {!readOnly && depth < 3 && !(locked && !parent && q.id !== null) && (
            <button type="button" onClick={() => change(addPart(draft, q.key))} className={QUIET}>
              Add part
            </button>
          )}
          {!readOnly && (
            <>
              <button type="button" onClick={() => change(moveQuestion(draft, q.key, -1))} disabled={index <= 0} aria-label={`Move ${name} up`} className={QUIET}>
                ↑
              </button>
              <button
                type="button"
                onClick={() => change(moveQuestion(draft, q.key, 1))}
                disabled={index >= siblings.length - 1}
                aria-label={`Move ${name} down`}
                className={QUIET}
              >
                ↓
              </button>
            </>
          )}
          {!readOnly && !fixed(q) && (
            <button type="button" onClick={() => change(removeQuestion(draft, q.key))} className={QUIET}>
              Remove
            </button>
          )}
        </div>

        {errs.length > 0 && (
          <ul role="alert" className="mt-2 list-disc pl-5 text-sm text-red-700">
            {errs.map((e, i) => (
              <li key={i}>{e.message}</li>
            ))}
          </ul>
        )}

        {panel && schemePanel(q, name)}
      </li>
    );
  }

  function schemePanel(q: DraftQuestion, name: string) {
    const setPoint = (i: number, p: Partial<DraftPoint>) => edit(q.key, { points: q.points.map((x, j) => (j === i ? { ...x, ...p } : x)) });
    return (
      <div className="mt-3 space-y-3 rounded border border-slate-200 bg-slate-50 p-3">
        <div>
          <h4 className="text-xs font-semibold text-slate-700">Marking points</h4>
          {q.points.length === 0 && <p className="mt-1 text-xs text-slate-500">No marking points yet.</p>}
          <ul className="mt-2 space-y-2">
            {q.points.map((p, i) => (
              <li key={i} className="flex flex-wrap items-end gap-2">
                <label className="flex flex-col">
                  <span className={FIELD_LABEL}>Label</span>
                  <input
                    value={p.label ?? ""}
                    onChange={(e) => setPoint(i, { label: e.target.value })}
                    placeholder={q.levels ? "L2" : "M1"}
                    maxLength={POINT_LABEL_MAX}
                    disabled={readOnly}
                    aria-label={`Label of marking point ${i + 1} of ${name}`}
                    className={`${INPUT} w-20`}
                  />
                </label>
                <label className="flex flex-col">
                  <span className={FIELD_LABEL}>Marks</span>
                  <input
                    type="number"
                    inputMode="decimal"
                    min={0}
                    step={0.5}
                    value={Number.isFinite(p.marks) ? p.marks : ""}
                    onChange={(e) => setPoint(i, { marks: toNumber(e.target.value) ?? Number.NaN })}
                    disabled={readOnly}
                    aria-label={`Marks of marking point ${i + 1} of ${name}`}
                    className={`${INPUT} w-20`}
                  />
                </label>
                {q.levels && (
                  <label className="flex flex-col">
                    <span className={FIELD_LABEL}>Up to</span>
                    <input
                      type="number"
                      inputMode="decimal"
                      min={0}
                      step={0.5}
                      value={p.marksTo ?? ""}
                      onChange={(e) => setPoint(i, { marksTo: toNumber(e.target.value) })}
                      disabled={readOnly}
                      aria-label={`Top of the band of marking point ${i + 1} of ${name}`}
                      className={`${INPUT} w-20`}
                    />
                  </label>
                )}
                <label className="flex min-w-48 flex-1 flex-col">
                  <span className={FIELD_LABEL}>Text</span>
                  <input
                    value={p.text}
                    onChange={(e) => setPoint(i, { text: e.target.value })}
                    maxLength={POINT_TEXT_MAX}
                    disabled={readOnly}
                    aria-label={`Text of marking point ${i + 1} of ${name}`}
                    className={INPUT}
                  />
                </label>
                {!readOnly && (
                  <button type="button" onClick={() => edit(q.key, { points: q.points.filter((_, j) => j !== i) })} className={QUIET}>
                    Remove
                  </button>
                )}
              </li>
            ))}
          </ul>
          {!readOnly && (
            <button
              type="button"
              onClick={() => edit(q.key, { points: [...q.points, { label: null, marks: 1, marksTo: null, text: "" }] })}
              className={`${QUIET} mt-2`}
            >
              Add marking point
            </button>
          )}
        </div>
        <label className="block">
          <span className={FIELD_LABEL}>Acceptable alternatives</span>
          <textarea
            value={q.alternatives}
            onChange={(e) => edit(q.key, { alternatives: e.target.value })}
            rows={2}
            maxLength={ALTERNATIVES_MAX}
            disabled={readOnly}
            className={`${INPUT} mt-1 w-full`}
          />
        </label>
        <label className="block">
          <span className={FIELD_LABEL}>Guidance</span>
          <textarea
            value={q.guidance}
            onChange={(e) => edit(q.key, { guidance: e.target.value })}
            rows={3}
            maxLength={GUIDANCE_MAX}
            disabled={readOnly}
            className={`${INPUT} mt-1 w-full`}
          />
        </label>
      </div>
    );
  }

  const structureErrors = rowErrors("structure");

  return (
    <div className="space-y-5 pb-24">
      <div className="flex flex-wrap items-baseline justify-between gap-3">
        <p data-testid="paper-total" className="text-xl font-semibold text-slate-900">
          Paper total: {marksText(total)}
        </p>
        {dirty && <p className="text-sm text-slate-500">Not saved yet.</p>}
      </div>

      {locked && (
        <div role="status" className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          Marking has started. Changes need a reason and are recorded.{readOnly ? " Only an admin can change it now." : ""}
        </div>
      )}
      {!paper && (
        <div role="status" className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">
          This exam has no question paper yet, so pages cannot be chosen.
        </div>
      )}

      <Card title="Questions">
        {draft.questions.length === 0 && <p className="mb-3 text-sm text-slate-500">No questions yet.</p>}
        {structureErrors.length > 0 && (
          <p role="alert" className="mb-3 text-sm text-red-700">
            {structureErrors.map((e) => e.message).join(" ")}
          </p>
        )}
        <ul className="space-y-2">
          {draft.questions.map((q) => questionRow(q))}
        </ul>
        {!readOnly && (
          <button type="button" onClick={() => change(addQuestion(draft))} className={`${QUIET} mt-3`}>
            Add question
          </button>
        )}
      </Card>

      <Card title="Optional questions">
        <p className="mb-3 text-sm text-slate-600">For questions the candidate chooses between. Set &ldquo;Optional with…&rdquo; on each of them.</p>
        <ul className="space-y-2">
          {draft.optionGroups.map((o) => {
            const members = draft.questions.filter((q) => q.optionGroupKey === o.key).map((q) => fullLabel(draft, q.key));
            const errs = rowErrors(o.key);
            return (
              <li key={o.key} className="rounded border border-slate-200 p-3">
                <div className="flex flex-wrap items-end gap-3">
                  <label className="flex flex-col">
                    <span className={FIELD_LABEL}>Name</span>
                    <input
                      value={o.label}
                      onChange={(e) => change({ ...draft, optionGroups: draft.optionGroups.map((x) => (x.key === o.key ? { ...x, label: e.target.value } : x)) })}
                      maxLength={OPTION_LABEL_MAX}
                      disabled={readOnly || locked}
                      placeholder="Section B"
                      className={INPUT}
                    />
                  </label>
                  <label className="flex items-center gap-2 pb-2 text-sm text-slate-700">
                    Answer
                    <input
                      type="number"
                      min={1}
                      step={1}
                      value={Number.isFinite(o.choose) ? o.choose : ""}
                      onChange={(e) =>
                        change({ ...draft, optionGroups: draft.optionGroups.map((x) => (x.key === o.key ? { ...x, choose: toNumber(e.target.value) ?? Number.NaN } : x)) })
                      }
                      disabled={readOnly || locked}
                      aria-label={`How many to answer of ${o.label || "these optional questions"}`}
                      className={`${INPUT} w-16`}
                    />
                    of these{members.length ? `: ${members.join(", ")}` : ""}
                  </label>
                  {!readOnly && !locked && (
                    <button
                      type="button"
                      onClick={() =>
                        change({
                          ...draft,
                          optionGroups: draft.optionGroups.filter((x) => x.key !== o.key),
                          questions: draft.questions.map((q) => (q.optionGroupKey === o.key ? { ...q, optionGroupKey: null } : q)),
                        })
                      }
                      className={QUIET}
                    >
                      Remove
                    </button>
                  )}
                </div>
                {errs.length > 0 && (
                  <ul role="alert" className="mt-2 list-disc pl-5 text-sm text-red-700">
                    {errs.map((e, i) => (
                      <li key={i}>{e.message}</li>
                    ))}
                  </ul>
                )}
              </li>
            );
          })}
        </ul>
        {!readOnly && !locked && (
          <button
            type="button"
            onClick={() => change({ ...draft, optionGroups: [...draft.optionGroups, { key: newKey("option"), label: "", choose: 1 }] })}
            className={`${QUIET} mt-3`}
          >
            Add optional questions
          </button>
        )}
      </Card>

      <Card title="Question groups">
        <p className="mb-3 text-sm text-slate-600">Used when the exam is marked by question: each group is marked separately.</p>
        <ul className="space-y-2">
          {draft.groups.map((g) => {
            const members = draft.questions.filter((q) => q.groupKey === g.key).map((q) => fullLabel(draft, q.key));
            const errs = rowErrors(g.key);
            return (
              <li key={g.key} className="rounded border border-slate-200 p-3">
                <div className="flex flex-wrap items-end gap-3">
                  <label className="flex flex-col">
                    <span className={FIELD_LABEL}>Name</span>
                    <input
                      value={g.label}
                      onChange={(e) => change({ ...draft, groups: draft.groups.map((x) => (x.key === g.key ? { ...x, label: e.target.value } : x)) })}
                      maxLength={GROUP_LABEL_MAX}
                      disabled={readOnly || locked}
                      className={INPUT}
                    />
                  </label>
                  <span className="pb-2 text-sm text-slate-600">{members.length ? `Questions ${members.join(", ")}` : "No questions yet"}</span>
                  {!readOnly && !locked && (
                    <button
                      type="button"
                      onClick={() =>
                        change({
                          ...draft,
                          groups: draft.groups.filter((x) => x.key !== g.key),
                          questions: draft.questions.map((q) => (q.groupKey === g.key ? { ...q, groupKey: null } : q)),
                        })
                      }
                      className={QUIET}
                    >
                      Remove
                    </button>
                  )}
                </div>
                {errs.length > 0 && (
                  <ul role="alert" className="mt-2 list-disc pl-5 text-sm text-red-700">
                    {errs.map((e, i) => (
                      <li key={i}>{e.message}</li>
                    ))}
                  </ul>
                )}
              </li>
            );
          })}
        </ul>
        {!readOnly && !locked && (
          <button
            type="button"
            onClick={() => change({ ...draft, groups: [...draft.groups, { key: newKey("group"), label: `Group ${draft.groups.length + 1}` }] })}
            className={`${QUIET} mt-3`}
          >
            Add group
          </button>
        )}
      </Card>

      <Card title="Mark scheme PDF">
        {view.markSchemeFile ? (
          <p className="text-sm text-slate-700">A mark scheme PDF is attached. Markers of this subject can read it.</p>
        ) : (
          <p className="text-sm text-slate-500">No mark scheme PDF is attached.</p>
        )}
        {!readOnly && (
          <div className="mt-3 flex flex-wrap items-center gap-3">
            <label className={`${BUTTON} cursor-pointer focus-within:outline focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-blue-600 ${upload?.state === "uploading" ? "pointer-events-none opacity-50" : ""}`}>
              Attach the mark scheme PDF
              <input
                type="file"
                accept="application/pdf,.pdf"
                className="sr-only"
                disabled={upload?.state === "uploading"}
                onChange={(e) => {
                  chooseFile(e.target.files?.[0]);
                  e.target.value = "";
                }}
              />
            </label>
            {view.markSchemeFile && (
              <button type="button" onClick={() => setRemoving(true)} disabled={busy || upload?.state === "uploading"} className={QUIET}>
                Remove
              </button>
            )}
            <span className="text-xs text-slate-500">One PDF, up to 20 MB. A new one replaces the old.</span>
          </div>
        )}
        {upload?.state === "uploading" && (
          <p aria-live="polite" className="mt-2 text-sm text-slate-700">
            Uploading {upload.file.name}: {Math.round(upload.progress * 100)}%
          </p>
        )}
        {upload?.state === "failed" && (
          <div role="alert" className="mt-2 flex flex-wrap items-center gap-3 text-sm text-red-700">
            {upload.error}
            <button type="button" onClick={() => void sendFile(upload)} className={QUIET}>
              Try again
            </button>
          </div>
        )}
        <div aria-live="polite">{fileNote?.tone === "ok" && <p className="mt-2 text-sm text-slate-700">{fileNote.text}</p>}</div>
        {fileNote?.tone === "error" && (
          <p role="alert" className="mt-2 text-sm text-red-700">
            {fileNote.text}
          </p>
        )}
      </Card>

      {!readOnly && (
        <div className="sticky bottom-0 z-10 -mx-6 border-t border-slate-200 bg-white px-6 py-3 shadow-[0_-2px_6px_rgba(15,23,42,0.06)]">
          <div className="flex flex-wrap items-end gap-3">
            {locked && (
              <label className="flex min-w-64 flex-1 flex-col">
                <span className={FIELD_LABEL}>Reason for the change (3 to 300 characters, recorded)</span>
                <input value={reason} onChange={(e) => setReason(e.target.value)} maxLength={REASON_MAX} className={INPUT} />
              </label>
            )}
            <button type="button" onClick={() => void save()} disabled={busy || !dirty} className={BUTTON}>
              {busy ? "Saving…" : "Save"}
            </button>
            <div aria-live="polite" className="text-sm">
              {note?.tone === "ok" && <span className="text-slate-700">{note.text}</span>}
            </div>
            {note?.tone === "error" && (
              <p role="alert" className="text-sm text-red-700">
                {note.text}
              </p>
            )}
          </div>
        </div>
      )}

      {removing && (
        <ReasonDialog
          title="Remove the mark scheme PDF"
          confirmLabel="Remove"
          tone="danger"
          busy={busy}
          error={removeError}
          onConfirm={(why) => void removeFile(why)}
          onCancel={() => {
            setRemoving(false);
            setRemoveError(null);
          }}
        >
          <p className="text-sm text-slate-700">Markers will no longer see it. The file is kept in the record.</p>
        </ReasonDialog>
      )}
    </div>
  );
}
