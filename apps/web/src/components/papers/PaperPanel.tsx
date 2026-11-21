"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { registerExamPaper } from "@stem/shared";
import { Badge, Card } from "@/components/AppShell";
import { ConfirmDialog } from "@/components/accounts/ConfirmDialog";
import { ReasonDialog, REASON_MAX, REASON_MIN } from "@/components/papers/ReasonDialog";
import { removeInsertAction } from "@/app/admin/exams/[id]/actions";
import { createClient } from "@/lib/supabase/client";
import { formatLondon } from "@/lib/money";
import { PageRolesPanel } from "@/components/papers/PageRolesPanel";
import type { PaperLayout, PaperVersion } from "@/lib/exam-admin";

/** Paper PDFs are at most 20 MB (the bucket and the paper-register function enforce the same limit). */
export const MAX_PAPER_BYTES = 20 * 1024 * 1024;

const size = (b: number) => (b >= 1024 * 1024 ? `${(b / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(b / 1024))} KB`);

type Mode = { kind: "paper" } | { kind: "insert" };
type Dialog = { type: "upload"; mode: Mode } | { type: "remove"; insert: PaperVersion } | null;

/** The exam's question paper (upload, replace, version history) and its inserts. */
export function PaperPanel({
  examId,
  papers,
  currentHasCopies,
  layout,
  locked,
}: {
  examId: string;
  papers: PaperVersion[];
  currentHasCopies: boolean;
  /** Page roles and hidden areas of the current paper. */
  layout: PaperLayout | null;
  /** The exam is cancelled or finished: nothing can be uploaded. */
  locked: boolean;
}) {
  const router = useRouter();
  const [dialog, setDialog] = useState<Dialog>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const paperVersions = papers.filter((p) => p.kind === "paper");
  const current = paperVersions.find((p) => p.current) ?? null;
  const inserts = papers.filter((p) => p.kind === "insert" && p.current);

  function close() {
    setDialog(null);
    setError(null);
  }

  async function removeInsert(insert: PaperVersion, reason: string) {
    setBusy(true);
    setError(null);
    const res = await removeInsertAction(examId, insert.id, reason).catch(() => ({ ok: false as const, message: "Something went wrong. Please try again." }));
    setBusy(false);
    if (res.ok) {
      setDialog(null);
      setNotice(res.message);
      router.refresh();
    } else {
      setError(res.message);
    }
  }

  return (
    <Card title="Question paper">
      {notice && (
        <div role="status" className="mb-3 rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">
          {notice}
        </div>
      )}

      {current ? (
        <div data-testid="current-paper" className="flex flex-wrap items-center justify-between gap-3">
          <div className="text-sm">
            <div className="flex items-center gap-2">
              <span className="font-medium text-slate-900">Version {current.version}</span>
              <Badge tone="green">Current</Badge>
            </div>
            <div className="text-xs text-slate-500">
              {current.pageCount} page{current.pageCount === 1 ? "" : "s"} · {size(current.byteSize)} · uploaded by {current.uploadedBy}, {formatLondon(current.uploadedAt)}
            </div>
          </div>
          {!locked && (
            <button type="button" onClick={() => setDialog({ type: "upload", mode: { kind: "paper" } })} className="rounded border border-slate-300 px-3 py-1.5 text-sm hover:bg-slate-50">
              Replace paper
            </button>
          )}
        </div>
      ) : (
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-sm text-slate-600">No paper has been uploaded yet.</p>
          {!locked && (
            <button type="button" onClick={() => setDialog({ type: "upload", mode: { kind: "paper" } })} className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700">
              Upload paper
            </button>
          )}
        </div>
      )}

      {paperVersions.length > 0 && (
        <div className="mt-5">
          <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">Version history</h3>
          <div className="overflow-x-auto">
            <table aria-label="Paper versions" className="w-full text-left text-sm">
              <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  {["Version", "Pages", "Size", "Uploaded by", "When (UK time)", "Reason for replacing"].map((h) => (
                    <th key={h} className="py-2 pr-4 font-medium">
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {paperVersions.map((p) => (
                  <tr key={p.id} data-testid="paper-version" className="border-b border-slate-100 last:border-0">
                    <td className="py-2 pr-4 whitespace-nowrap">
                      v{p.version} {p.current && <Badge tone="green">Current</Badge>}
                    </td>
                    <td className="py-2 pr-4">{p.pageCount}</td>
                    <td className="py-2 pr-4 whitespace-nowrap">{size(p.byteSize)}</td>
                    <td className="py-2 pr-4">{p.uploadedBy}</td>
                    <td className="py-2 pr-4 whitespace-nowrap">{formatLondon(p.uploadedAt)}</td>
                    <td className="py-2 pr-4 text-slate-600">{p.replaceReason ?? ""}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {current && layout && <PageRolesPanel key={current.id} examId={examId} paper={current} layout={layout} locked={locked} />}

      <div className="mt-6 border-t border-slate-100 pt-4">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h3 className="text-sm font-semibold text-slate-800">Inserts</h3>
            <p className="text-xs text-slate-500">Data booklets, formula sheets and source booklets. They go out with the paper, unchanged.</p>
          </div>
          {!locked && (
            <button type="button" onClick={() => setDialog({ type: "upload", mode: { kind: "insert" } })} className="rounded border border-slate-300 px-3 py-1.5 text-sm hover:bg-slate-50">
              Add insert
            </button>
          )}
        </div>
        {inserts.length === 0 ? (
          <p className="mt-2 text-sm text-slate-500">No inserts.</p>
        ) : (
          <ul className="mt-2 divide-y divide-slate-100 text-sm">
            {inserts.map((i) => (
              <li key={i.id} data-testid="insert-row" className="flex flex-wrap items-center justify-between gap-2 py-2">
                <span>
                  <span className="font-medium">{i.title}</span>
                  <span className="ml-2 text-xs text-slate-500">
                    {i.pageCount} page{i.pageCount === 1 ? "" : "s"} · {size(i.byteSize)}
                  </span>
                </span>
                {!locked && (
                  <button type="button" onClick={() => setDialog({ type: "remove", insert: i })} className="rounded border border-red-300 px-3 py-1 text-xs font-medium text-red-700 hover:bg-red-50">
                    Remove
                  </button>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>

      {dialog?.type === "upload" && (
        <UploadDialog
          examId={examId}
          mode={dialog.mode}
          needsReason={dialog.mode.kind === "paper" && current !== null && currentHasCopies}
          replacing={dialog.mode.kind === "paper" && current !== null}
          onCancel={close}
          onDone={(message) => {
            setDialog(null);
            setNotice(message);
            router.refresh();
          }}
        />
      )}
      {dialog?.type === "remove" && (
        <ReasonDialog
          title={`Remove ${dialog.insert.title}?`}
          confirmLabel="Remove insert"
          tone="danger"
          busy={busy}
          error={error}
          onConfirm={(reason) => removeInsert(dialog.insert, reason)}
          onCancel={close}
        >
          <p>It stays in the history, but families and print packs no longer get it.</p>
        </ReasonDialog>
      )}
    </Card>
  );
}

/** Picks a PDF, uploads it with the admin's own session, then registers it. The reason is asked for before the upload so a large file is never wasted. */
function UploadDialog({
  examId,
  mode,
  needsReason,
  replacing,
  onCancel,
  onDone,
}: {
  examId: string;
  mode: Mode;
  needsReason: boolean;
  replacing: boolean;
  onCancel: () => void;
  onDone: (message: string) => void;
}) {
  const fileRef = useRef<HTMLInputElement>(null);
  const [title, setTitle] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [forceReason, setForceReason] = useState(false);
  const router = useRouter();
  const mustGiveReason = needsReason || forceReason;
  const isInsert = mode.kind === "insert";
  const heading = isInsert ? "Add an insert" : replacing ? "Replace the paper" : "Upload the paper";

  async function submit() {
    setError(null);
    const file = fileRef.current?.files?.[0];
    if (!file) return setError("Choose a PDF file.");
    if (file.type !== "application/pdf" && !/\.pdf$/i.test(file.name)) return setError("The file must be a PDF.");
    if (file.size > MAX_PAPER_BYTES) return setError("This PDF is larger than 20 MB. Make it smaller and upload it again.");
    const cleanTitle = title.trim();
    if (isInsert && (cleanTitle.length < 1 || cleanTitle.length > 120)) return setError("Give the insert a title of up to 120 characters.");
    const cleanReason = reason.trim();
    if (mustGiveReason && (cleanReason.length < REASON_MIN || cleanReason.length > REASON_MAX)) return setError("Give a reason of 3 to 300 characters.");

    setBusy(true);
    const client = createClient();
    const storagePath = `${examId}/${crypto.randomUUID()}.pdf`;
    const up = await client.storage.from("exam-papers").upload(storagePath, file, { contentType: "application/pdf", upsert: false });
    if (up.error) {
      setBusy(false);
      return setError("The file could not be uploaded. Please try again.");
    }
    const res = await registerExamPaper(client, {
      examId,
      kind: mode.kind,
      ...(isInsert ? { title: cleanTitle } : {}),
      storagePath,
      ...(cleanReason ? { reason: cleanReason } : {}),
    });
    setBusy(false);
    if ("error" in res) {
      // A copy was made since this page loaded, so a reason is now needed. The refused file is already gone;
      // keep the dialog open with the reason field and upload again on the next press.
      if (res.error.code === "invalid_input" && replacing && !cleanReason) {
        setForceReason(true);
        router.refresh();
        return setError("Copies of the current paper now exist. Say why you are replacing it, then upload again.");
      }
      return setError(res.error.message);
    }
    onDone(isInsert ? `Insert added (${res.data.pageCount} pages).` : `Paper version ${res.data.version} uploaded (${res.data.pageCount} pages).`);
  }

  return (
    <ConfirmDialog title={heading} confirmLabel={busy ? "Uploading..." : "Upload"} tone="primary" busy={busy} onConfirm={submit} onCancel={() => { if (!busy) onCancel(); }}>
      <div className="space-y-3">
        {replacing && (
          <p>
            {mustGiveReason
              ? "Copies of the current paper already exist. They stay valid, and the new version gets new codes. Say why you are replacing it."
              : "The new version replaces the current one. The old version stays in the history."}
          </p>
        )}
        {isInsert && (
          <label className="block text-sm">
            <span className="font-medium text-slate-700">Title</span>
            <input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={120} className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm" />
          </label>
        )}
        {mustGiveReason && (
          <label className="block text-sm">
            <span className="font-medium text-slate-700">Reason for replacing</span>
            <textarea value={reason} onChange={(e) => setReason(e.target.value)} rows={3} maxLength={REASON_MAX} className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm" />
            <span className="text-xs text-slate-500">3 to 300 characters. It goes into the audit log.</span>
          </label>
        )}
        <label className="block text-sm">
          <span className="font-medium text-slate-700">PDF file (up to 20 MB)</span>
          <input ref={fileRef} type="file" accept="application/pdf,.pdf" className="mt-1 block w-full text-sm" />
        </label>
        {error && (
          <p role="alert" className="text-sm text-red-700">
            {error}
          </p>
        )}
      </div>
    </ConfirmDialog>
  );
}
