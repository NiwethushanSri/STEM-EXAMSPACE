"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { scanMessageFor } from "@stem/shared";
import { Card } from "@/components/AppShell";
import { storeFile } from "@/lib/home-upload";
import { uploadResumable } from "@/lib/resumable-upload";
import {
  SCAN_ACCEPT,
  SCAN_POLL_MAX_FAILURES,
  SCAN_POLL_MS,
  completeFailureMessage,
  completeSummary,
  fileSize,
  hasUploadsInFlight,
  isProcessing,
  named,
  parseCompleteResult,
  parseScanStatus,
  scanFileProblem,
  scanFileType,
  startPolling,
  totalsLine,
  type ScanBatchStatus,
} from "@/lib/scan-batch";
import { createClient } from "@/lib/supabase/client";

const BUTTON = "rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50";
const QUIET = "rounded border border-slate-300 bg-white px-3 py-1 text-xs font-medium text-slate-800 hover:bg-slate-50 disabled:opacity-50";
/** A label around a visually hidden file input shows the input's focus. */
const FOCUS_WITHIN = "focus-within:outline focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-blue-600";

export type ScanCentre = { id: string; venue: string; room: string };

/** One file chosen on this screen, until processing starts. */
type LocalFile = {
  key: string;
  batchId: string;
  name: string;
  size: number;
  mime: string;
  /** The file itself, until it is stored. */
  file: File | null;
  uploadId: string | null;
  path: string | null;
  state: "waiting" | "uploading" | "stored" | "failed";
  progress: number;
  error: string | null;
};

type Rpc = { ok?: boolean; code?: string } & Record<string, unknown>;
type Note = { tone: "ok" | "error"; text: string };

async function currentToken(): Promise<string | null> {
  return (await createClient().auth.getSession()).data.session?.access_token ?? null;
}

/** A scan RPC's answer: the object, or a failure code ("internal" when the call itself failed). */
async function call(name: string, args: Record<string, unknown>): Promise<Rpc> {
  const { data, error } = await (createClient().rpc as unknown as (n: string, a: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>)(
    name,
    args,
  );
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, code: "internal" };
  return data as Rpc;
}

const UPLOAD_STATE: Record<string, string> = {
  pending: "Not uploaded",
  stored: "Uploaded",
  queued: "Waiting to be processed",
  processing: "Processing",
  processed: "Processed",
  failed: "Could not be processed",
};

let keys = 0;
const newKey = () => `s${++keys}`;

/** A note: an ok note in a polite live region (always there), an error as an alert. */
function NoteLine({ note }: { note: Note | undefined }) {
  return (
    <>
      <div aria-live="polite">{note?.tone === "ok" && <p className="mt-2 text-sm text-slate-700">{note.text}</p>}</div>
      {note?.tone === "error" && (
        <p role="alert" className="mt-2 text-sm text-red-700">
          {note.text}
        </p>
      )}
    </>
  );
}

/**
 * Scans of a centre exam, per centre: "New scan batch" (optionally naming the collection manifest), the scanner files
 * uploaded straight to private storage with progress (resumable, one at a time), "Start processing", the live totals
 * (asked again 3 seconds after each answer while a job waits or runs; after 3 failures in a row it stops and offers
 * to try again) and "All scans for this centre are uploaded", which marks complete scripts and raises missing pages.
 * The database checks every rule again.
 */
export function ScanBatches({ examId, centres, batches: initial }: { examId: string; centres: ScanCentre[]; batches: ScanBatchStatus[] }) {
  const [batches, setBatches] = useState<ScanBatchStatus[]>(initial);
  const [manifest, setManifest] = useState<Record<string, string>>({});
  const [centreNote, setCentreNote] = useState<Record<string, Note | undefined>>({});
  const [batchNote, setBatchNote] = useState<Record<string, Note | undefined>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const [pollFailed, setPollFailed] = useState(false);

  const filesRef = useRef<LocalFile[]>([]);
  const [files, setFilesState] = useState<LocalFile[]>([]);
  const setFiles = useCallback((f: (fs: LocalFile[]) => LocalFile[]) => {
    filesRef.current = f(filesRef.current);
    setFilesState(filesRef.current);
  }, []);
  const patch = useCallback((key: string, p: Partial<LocalFile>) => setFiles((fs) => fs.map((x) => (x.key === key ? { ...x, ...p } : x))), [setFiles]);
  /** Uploads, one at a time (scanner files are large). */
  const queue = useRef<Promise<void>>(Promise.resolve());

  /** Asks for these batches' status again; false when any answer did not arrive. */
  const refresh = useCallback(async (ids: string[]): Promise<boolean> => {
    const got = await Promise.all(ids.map(async (id) => parseScanStatus(await call("scan_batch_status", { p_batch: id }))));
    setBatches((bs) => bs.map((b) => got.find((g) => g?.id === b.id) ?? b));
    return got.every((g) => g !== null);
  }, []);

  // Live totals: while a job of a batch waits or runs, its status is asked for again, one ask at a time.
  const active = batches.filter(isProcessing).map((b) => b.id).join(",");
  useEffect(() => {
    if (!active || pollFailed) return;
    const ids = active.split(",");
    return startPolling(() => refresh(ids), { intervalMs: SCAN_POLL_MS, maxFailures: SCAN_POLL_MAX_FAILURES, onGiveUp: () => setPollFailed(true) });
  }, [active, refresh, pollFailed]);

  async function createBatch(centreId: string) {
    setBusy(`create:${centreId}`);
    setCentreNote((m) => ({ ...m, [centreId]: undefined }));
    const number = (manifest[centreId] ?? "").trim();
    const r = await call("scan_batch_create", { p_exam: examId, p_centre: centreId, p_manifest_number: number || null });
    if (r.ok === true && typeof r.batch_id === "string") {
      const s = parseScanStatus(await call("scan_batch_status", { p_batch: r.batch_id }));
      if (s) setBatches((bs) => [...bs, s]);
      setManifest((m) => ({ ...m, [centreId]: "" }));
      setCentreNote((m) => ({ ...m, [centreId]: { tone: "ok", text: `Scan batch ${String(r.number)} made. Add its files below.` } }));
    } else {
      setCentreNote((m) => ({ ...m, [centreId]: { tone: "error", text: scanMessageFor(r.code, "create") } }));
    }
    setBusy(null);
  }

  /** Begins (once), uploads and stores one file; a retry asks the server first (storeFile). */
  async function uploadOne(key: string) {
    const f = filesRef.current.find((x) => x.key === key);
    if (!f || !f.file || f.state === "stored") return;
    const file = f.file;
    patch(key, { state: "uploading", progress: 0, error: null });
    try {
      await storeFile(
        { uploadId: f.uploadId, path: f.path },
        {
          begin: async () => {
            const r = await call("scan_upload_begin", { p_batch: f.batchId, p_mime: f.mime, p_bytes: f.size });
            if (r.ok !== true) throw new Error(String(r.code ?? "internal"));
            return { uploadId: String(r.upload_id), path: String(r.storage_path) };
          },
          upload: async (path) => {
            const token = await currentToken();
            if (!token) throw new Error("unauthenticated");
            await uploadResumable(file, {
              bucket: "script-uploads",
              path,
              accessToken: token,
              getAccessToken: currentToken,
              contentType: f.mime,
              onProgress: (sent, total) => patch(key, { progress: total ? sent / total : 0 }),
            });
          },
          stored: async (id) => {
            const r = await call("script_upload_stored", { p_upload: id });
            return { ok: r.ok === true, code: r.code };
          },
        },
        (id, path) => {
          patch(key, { uploadId: id, path });
          return true;
        },
      );
      patch(key, { state: "stored", progress: 1, file: null });
      void refresh([f.batchId]);
    } catch (e) {
      const code = e instanceof Error ? e.message : "internal";
      patch(key, { state: "failed", error: code === "unauthenticated" ? "Please sign in again." : scanMessageFor(code, "upload") });
    }
  }

  function enqueue(key: string) {
    queue.current = queue.current.then(() => uploadOne(key)).catch(() => undefined);
  }

  function addFiles(batchId: string, list: File[]) {
    const problems: string[] = [];
    const added: LocalFile[] = [];
    for (const file of list) {
      const mime = scanFileType(file.name, file.type);
      const problem = mime ? scanFileProblem(file.size) : "wrong_file_type";
      if (!mime || problem) {
        problems.push(`${file.name || "A file"}: ${scanMessageFor(problem, "upload")}`);
        continue;
      }
      added.push({ key: newKey(), batchId, name: file.name, size: file.size, mime, file, uploadId: null, path: null, state: "waiting", progress: 0, error: null });
    }
    setBatchNote((m) => ({ ...m, [batchId]: problems.length ? { tone: "error", text: problems.join(" ") } : undefined }));
    if (!added.length) return;
    setFiles((fs) => [...fs, ...added]);
    for (const f of added) enqueue(f.key);
  }

  async function submit(b: ScanBatchStatus) {
    setBusy(`submit:${b.id}`);
    setBatchNote((m) => ({ ...m, [b.id]: undefined }));
    const r = await call("scan_batch_submit", { p_batch: b.id });
    if (r.ok === true) {
      // Files that did not finish uploading are left out by the server.
      setFiles((fs) => fs.filter((f) => f.batchId !== b.id));
      setBatchNote((m) => ({ ...m, [b.id]: { tone: "ok", text: "Processing has started. The totals update as pages are read." } }));
    } else {
      setBatchNote((m) => ({ ...m, [b.id]: { tone: "error", text: scanMessageFor(r.code, "submit") } }));
    }
    await refresh([b.id]);
    setBusy(null);
  }

  async function completeCentre(centreId: string) {
    setBusy(`complete:${centreId}`);
    setCentreNote((m) => ({ ...m, [centreId]: undefined }));
    const r = await call("scan_centre_complete", { p_exam: examId, p_centre: centreId });
    const res = parseCompleteResult(r);
    setCentreNote((m) => ({
      ...m,
      [centreId]: res ? { tone: "ok", text: completeSummary(res) } : { tone: "error", text: completeFailureMessage(r) },
    }));
    await refresh(batches.filter((b) => b.centreId === centreId).map((b) => b.id));
    setBusy(null);
  }

  return (
    <Card title="Scans">
      <p className="mb-4 text-sm text-slate-600">
        Upload the office scanner&apos;s files for each centre. Each page is matched to its candidate by the code printed on it.
      </p>
      {pollFailed && (
        <div role="alert" className="mb-4 flex flex-wrap items-center gap-3 rounded border border-red-200 bg-red-50 p-3 text-sm text-red-800">
          The totals could not be updated. Check your connection.
          <button type="button" className={QUIET} onClick={() => setPollFailed(false)}>
            Update the totals again
          </button>
        </div>
      )}
      <div className="space-y-5">
        {centres.map((c) => {
          const mine = batches.filter((b) => b.centreId === c.id);
          const latest = mine[mine.length - 1];
          const label = `${c.venue} · ${c.room}`;
          const uploading = hasUploadsInFlight(files, mine.map((b) => b.id));
          const completeText = busy === `complete:${c.id}` ? "Checking scripts..." : "All scans for this centre are uploaded";
          return (
            <section key={c.id} data-testid="scan-centre" aria-label={`Scans for ${label}`} className="rounded border border-slate-200 p-4">
              <div className="flex flex-wrap items-start justify-between gap-3">
                <div>
                  <div className="font-medium text-slate-900">{label}</div>
                  {latest && (
                    <div className="text-xs text-slate-500" data-testid="scan-complete-count">
                      Complete scripts: {latest.candidatesComplete} of {latest.candidatesExpected} candidate{latest.candidatesExpected === 1 ? "" : "s"} present or late ·{" "}
                      {latest.totals.accepted} accepted
                    </div>
                  )}
                </div>
                <div className="flex flex-wrap items-end gap-2">
                  <label className="text-xs text-slate-600">
                    Manifest number (optional)
                    <input
                      type="text"
                      value={manifest[c.id] ?? ""}
                      onChange={(e) => setManifest((m) => ({ ...m, [c.id]: e.target.value }))}
                      maxLength={60}
                      placeholder="M-..."
                      aria-label={named("Manifest number (optional)", label)}
                      className="mt-1 block w-44 rounded border border-slate-300 bg-white px-2 py-1.5 text-sm"
                    />
                  </label>
                  <button type="button" className={BUTTON} disabled={busy !== null} onClick={() => createBatch(c.id)} aria-label={named("New scan batch", label)}>
                    New scan batch
                  </button>
                </div>
              </div>

              {mine.length === 0 ? (
                <p className="mt-3 text-sm text-slate-500">No scans yet.</p>
              ) : (
                <ul className="mt-3 space-y-3">
                  {mine.map((b) => (
                    <BatchRow
                      key={b.id}
                      batch={b}
                      files={files.filter((f) => f.batchId === b.id)}
                      note={batchNote[b.id]}
                      busy={busy}
                      onFiles={(list) => addFiles(b.id, list)}
                      onRetry={enqueue}
                      onSubmit={() => submit(b)}
                    />
                  ))}
                </ul>
              )}

              <div className="mt-4 flex flex-wrap items-center gap-3 border-t border-slate-100 pt-3">
                <button
                  type="button"
                  className={BUTTON}
                  disabled={busy !== null || uploading}
                  onClick={() => completeCentre(c.id)}
                  aria-label={named(completeText, label)}
                >
                  {completeText}
                </button>
                {uploading && <span className="text-xs text-slate-500">Wait until every file of this centre is uploaded.</span>}
              </div>
              <NoteLine note={centreNote[c.id]} />
            </section>
          );
        })}
      </div>
    </Card>
  );
}

function BatchRow({
  batch: b,
  files,
  note,
  busy,
  onFiles,
  onRetry,
  onSubmit,
}: {
  batch: ScanBatchStatus;
  files: LocalFile[];
  note: Note | undefined;
  busy: string | null;
  onFiles: (list: File[]) => void;
  onRetry: (key: string) => void;
  onSubmit: () => void;
}) {
  const open = b.submittedAt === null;
  const localIds = new Set(files.map((f) => f.uploadId).filter((id): id is string => id !== null));
  const others = b.uploads.filter((u) => !localIds.has(u.id));
  const uploading = files.some((f) => f.state === "waiting" || f.state === "uploading");
  const failed = files.filter((f) => f.state === "failed").length;
  const stored = b.uploads.some((u) => u.state === "stored") || files.some((f) => f.state === "stored");
  const processing = isProcessing(b);
  const line = totalsLine(b.totals);
  const submitText = busy === `submit:${b.id}` ? "Starting..." : "Start processing";

  return (
    <li data-testid="scan-batch" className="rounded border border-slate-200 p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <span className="font-medium text-slate-900">{b.number}</span>
          {b.manifest && <span className="ml-2 text-sm text-slate-600">Manifest {b.manifest}</span>}
        </div>
        <span className="text-xs text-slate-500">{open ? "Adding files" : processing ? "Processing" : "Processed"}</span>
      </div>

      {(files.length > 0 || others.length > 0) && (
        <ul className="mt-2 space-y-1 text-sm">
          {others.map((u, i) => (
            <li key={u.id} className="flex flex-wrap justify-between gap-2 text-slate-700">
              <span>
                File {i + 1} · {fileSize(u.byteSize)}
              </span>
              <span className={u.state === "failed" ? "text-red-700" : "text-slate-500"}>{UPLOAD_STATE[u.state] ?? u.state}</span>
            </li>
          ))}
          {files.map((f) => (
            <li key={f.key} className="text-slate-700">
              <div className="flex flex-wrap justify-between gap-2">
                <span>
                  {f.name} · {fileSize(f.size)}
                </span>
                <span className={f.state === "failed" ? "text-red-700" : "text-slate-500"}>
                  {f.state === "stored" ? "Uploaded" : f.state === "failed" ? "Not uploaded" : f.state === "waiting" ? "Waiting" : `${Math.round(f.progress * 100)}%`}
                </span>
              </div>
              {(f.state === "uploading" || f.state === "waiting") && (
                <div
                  role="progressbar"
                  aria-label={`Upload of ${f.name}`}
                  aria-valuemin={0}
                  aria-valuemax={100}
                  aria-valuenow={Math.round(f.progress * 100)}
                  className="mt-1 h-2 overflow-hidden rounded bg-slate-200"
                >
                  <div className="h-full bg-blue-600 transition-[width]" style={{ width: `${Math.round(f.progress * 100)}%` }} />
                </div>
              )}
              {f.state === "failed" && (
                <p role="alert" className="mt-1 flex flex-wrap items-center gap-2 text-xs text-red-700">
                  {f.error}
                  {f.file && (
                    <button type="button" className={QUIET} onClick={() => onRetry(f.key)} aria-label={named("Try again", f.name)}>
                      Try again
                    </button>
                  )}
                </p>
              )}
            </li>
          ))}
        </ul>
      )}

      {open ? (
        <div className="mt-3 flex flex-wrap items-center gap-3">
          <label className={`cursor-pointer rounded border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-800 hover:bg-slate-50 ${FOCUS_WITHIN}`}>
            Add scan files
            <input
              type="file"
              multiple
              accept={SCAN_ACCEPT}
              className="sr-only"
              aria-label={named("Add scan files", b.number)}
              onChange={(e) => {
                const list = Array.from(e.target.files ?? []);
                e.target.value = "";
                if (list.length) onFiles(list);
              }}
            />
          </label>
          <button
            type="button"
            className={BUTTON}
            disabled={busy !== null || uploading || !stored}
            onClick={onSubmit}
            aria-label={named(submitText, b.number)}
          >
            {submitText}
          </button>
          {uploading && <span className="text-xs text-slate-500">Wait until every file is uploaded.</span>}
          {!uploading && failed > 0 && (
            <span className="text-xs text-amber-800">
              {failed} file{failed === 1 ? "" : "s"} did not upload and will be left out.
            </span>
          )}
        </div>
      ) : (
        <div className="mt-2 text-sm text-slate-700" data-testid="scan-totals">
          <p>{line}</p>
          {processing ? (
            <p className="text-xs text-slate-500">
              {b.jobs.queued} file{b.jobs.queued === 1 ? "" : "s"} waiting, {b.jobs.running} being processed. The totals update every few seconds.
            </p>
          ) : (
            b.jobs.failed > 0 && (
              <p className="text-xs text-red-700">
                {b.jobs.failed} file{b.jobs.failed === 1 ? "" : "s"} could not be processed. {b.jobs.failed === 1 ? "It is" : "They are"} listed in the exception queue.
              </p>
            )
          )}
        </div>
      )}
      {/* Always present, so a screen reader hears the totals only when the numbers change. */}
      <p className="sr-only" aria-live="polite">
        {open ? "" : `${b.number}: ${line}`}
      </p>

      <NoteLine note={note} />
    </li>
  );
}
