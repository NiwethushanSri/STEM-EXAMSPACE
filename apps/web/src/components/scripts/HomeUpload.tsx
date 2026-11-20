"use client";

import { useCallback, useEffect, useRef, useState, useSyncExternalStore, type DragEvent } from "react";
import { uploadMessageFor } from "@stem/shared";
import { CameraCapture } from "@/components/scripts/CameraCapture";
import { UploadReceipt } from "@/components/scripts/UploadReceipt";
import { inspectPhoto, isBlurred } from "@/lib/blur-check";
import {
  MAX_FILES,
  POLL_MS,
  UPLOAD_TEXT,
  afterSubmit,
  attentionItems,
  blankPrompt,
  canSubmit,
  fileProblem,
  isStale,
  retakePrompt,
  statusWord,
  storeFile,
  uploadFileType,
  uploadView,
  type HomeUploadStatus,
  type SubmitResult,
  type UploadKind,
} from "@/lib/home-upload";
import { uploadResumable } from "@/lib/resumable-upload";
import type { SittingPhase } from "@/lib/sitting-state";
import { createClient } from "@/lib/supabase/client";

const BUTTON =
  "rounded-lg bg-blue-700 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-800 disabled:cursor-not-allowed disabled:opacity-60";
const QUIET =
  "rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-sm font-semibold text-slate-800 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-60";
/** A label around a visually hidden file input shows the input's focus. */
const FOCUS_WITHIN = "focus-within:outline focus-within:outline-2 focus-within:outline-offset-2 focus-within:outline-blue-600";
const SMALL = "rounded border border-slate-300 bg-white px-2 py-0.5 text-xs font-semibold text-slate-700 hover:bg-slate-50 disabled:opacity-50";
const ACCEPT = ".pdf,.jpg,.jpeg,.png,.heic,.heif,application/pdf,image/jpeg,image/png,image/heic,image/heif";

/** One file of the draft as this screen knows it: a file chosen or photographed here, or one already on the server. */
type LocalFile = {
  key: string;
  uploadId: string | null;
  path: string | null;
  kind: UploadKind;
  mime: string;
  size: number;
  /** The file itself, until it is uploaded (gone after a reload). */
  file: File | null;
  /** A small thumbnail made here (object URL), for photos the browser can decode. */
  preview: string | null;
  /** elsewhere: being uploaded by another family member on their device. */
  state: "waiting" | "uploading" | "stored" | "failed" | "elsewhere";
  progress: number;
  error: string | null;
  blurred: boolean;
};

type Rpc = { ok?: boolean; code?: string } & Record<string, unknown>;

/** The signed-in person's current access token. */
async function currentToken(): Promise<string | null> {
  return (await createClient().auth.getSession()).data.session?.access_token ?? null;
}

/** The family's answer to an RPC: the object, or a failure code ("internal" when the call itself failed). */
async function call(name: string, args: Record<string, unknown>): Promise<Rpc> {
  const { data, error } = await (createClient().rpc as unknown as (n: string, a: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>)(
    name,
    args,
  );
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { ok: false, code: "internal" };
  return data as Rpc;
}

function subscribeCoarse(onChange: () => void) {
  const m = window.matchMedia("(pointer: coarse)");
  m.addEventListener("change", onChange);
  return () => m.removeEventListener("change", onChange);
}

let keys = 0;
const newKey = () => `f${++keys}`;

/**
 * Handing in the answers of a home booking, from the start of the exam: photos or a PDF upload straight to private
 * storage with progress (and resume), "Submit" hands them in, then the screen follows the server: "Checking your
 * pages" (asked again every 3 seconds), "Needs your attention" with what the family can do, or the receipt once the
 * server says "Received". Until the deadline the family can replace all pages or some. `phase` is the sitting's
 * phase on screen; the database decides every window again.
 */
export function HomeUpload({ bookingId, label, phase }: { bookingId: string; label: string; phase: SittingPhase }) {
  const canUpload = phase === "sitting" || phase === "upload_open" || phase === "late_window";
  const phone = useSyncExternalStore(subscribeCoarse, () => window.matchMedia("(pointer: coarse)").matches, () => false);

  const [status, setStatus] = useState<HomeUploadStatus | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [loads, setLoads] = useState(0);
  const [editing, setEditing] = useState(false);
  const [replaceAll, setReplaceAll] = useState(true);
  const [camera, setCamera] = useState<{ replace: string | null } | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState(false);
  const [dragKey, setDragKey] = useState<string | null>(null);
  const [placeChoice, setPlaceChoice] = useState<Record<string, string>>({});

  // The draft's files: kept in a ref (the upload queue reads the latest) and mirrored into state for rendering.
  const filesRef = useRef<LocalFile[]>([]);
  const [files, setFilesState] = useState<LocalFile[]>([]);
  const setFiles = useCallback((f: (fs: LocalFile[]) => LocalFile[]) => {
    filesRef.current = f(filesRef.current);
    setFilesState(filesRef.current);
  }, []);
  const patch = useCallback(
    (key: string, p: Partial<LocalFile>) => setFiles((fs) => fs.map((x) => (x.key === key ? { ...x, ...p } : x))),
    [setFiles],
  );
  const draftRef = useRef<string | null>(null);
  /** Uploads, one at a time. */
  const queue = useRef<Promise<void>>(Promise.resolve());
  /** Photo checks (blur and thumbnail), one decode at a time, apart from the uploads so feedback is quick. */
  const inspecting = useRef<Promise<void>>(Promise.resolve());
  /** The number of the submission this screen handed in: older statuses (replies sent before) are ignored. */
  const submittedSeq = useRef<number | null>(null);
  const statusHeading = useRef<HTMLHeadingElement>(null);
  const photographButton = useRef<HTMLButtonElement>(null);
  const focusNext = useRef<"status" | "photograph" | null>(null);
  const replaceInput = useRef<HTMLInputElement>(null);
  const replaceKey = useRef<string | null>(null);

  const fetchStatus = useCallback(async (): Promise<HomeUploadStatus | null> => {
    const r = await call("home_submission_status", { p_booking: bookingId });
    return r.ok === false ? null : (r as unknown as HomeUploadStatus);
  }, [bookingId]);

  /** Takes in a status from the server. The draft's files this page does not hold (after a reload, or added on
   * another device) follow the server: uploaded, still uploading on the other device, or (this person's, without
   * the file) not finished and to be deleted. Files this page holds keep their own progress. */
  const take = useCallback(
    (s: HomeUploadStatus | null) => {
      setLoadFailed(!s);
      if (!s || isStale(s, submittedSeq.current)) return;
      setStatus(s);
      draftRef.current = s.draft?.id ?? null;
      if (s.draft) setReplaceAll(s.draft.replaces_all);
      const uploads = s.draft?.uploads ?? [];
      const server = (u: (typeof uploads)[number]): Pick<LocalFile, "state" | "progress" | "error"> =>
        u.state === "stored"
          ? { state: "stored", progress: 1, error: null }
          : u.mine
            ? { state: "failed", progress: 0, error: UPLOAD_TEXT.notFinished }
            : { state: "elsewhere", progress: 0, error: null };
      // A file of this page whose upload row is being made could show up twice: new rows wait for the next look.
      const beginning = filesRef.current.some((f) => f.file && !f.uploadId);
      setFiles((fs) => {
        const byId = new Map(uploads.map((u) => [u.id, u]));
        const kept = fs.flatMap((f) => {
          if (f.file) return [f];
          const u = f.uploadId ? byId.get(f.uploadId) : undefined;
          return u ? [{ ...f, ...server(u) }] : [];
        });
        if (beginning) return kept;
        const known = new Set(kept.map((f) => f.uploadId));
        const more: LocalFile[] = uploads
          .filter((u) => !known.has(u.id))
          .map((u) => ({
            key: newKey(), uploadId: u.id, path: u.storage_path, kind: u.kind, mime: u.mime, size: u.byte_size,
            file: null, preview: null, blurred: false, ...server(u),
          }));
        return [...kept, ...more];
      });
    },
    [setFiles],
  );

  const load = useCallback(async () => {
    take(await fetchStatus());
    setLoads((n) => n + 1);
  }, [fetchStatus, take]);

  useEffect(() => {
    let live = true;
    void fetchStatus().then((s) => {
      if (live) take(s);
    });
    return () => {
      live = false;
    };
  }, [fetchStatus, take]);

  // While the pages are being checked, ask again every 3 seconds until the server has an answer.
  const checking = status?.submission?.state === "checking";
  useEffect(() => {
    if (!checking) return;
    const t = setTimeout(() => void load(), POLL_MS);
    return () => clearTimeout(t);
  }, [checking, loads, load]);

  // Back from the background: look again (a phone that slept while the pages were checked).
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible") void load();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, [load]);

  // After a submit the focus goes to where the answers stand; after the camera, back to "Photograph pages".
  useEffect(() => {
    if (focusNext.current === "status" && statusHeading.current) {
      statusHeading.current.focus();
      focusNext.current = null;
    } else if (focusNext.current === "photograph" && !camera && photographButton.current) {
      photographButton.current.focus();
      focusNext.current = null;
    }
  });

  // Local previews are let go when the screen closes.
  useEffect(
    () => () => {
      for (const f of filesRef.current) if (f.preview) URL.revokeObjectURL(f.preview);
    },
    [],
  );

  const present = (key: string) => filesRef.current.some((f) => f.key === key);

  async function ensureDraft(): Promise<string> {
    if (draftRef.current) return draftRef.current;
    const r = await call("home_submission_open", { p_booking: bookingId, p_replaces_all: replaceAll });
    if (r.ok !== true) throw new Error(String(r.code ?? "internal"));
    draftRef.current = String(r.submission_id);
    return draftRef.current;
  }

  /** Begins (once), uploads and stores one file (storeFile: a retry asks the server before sending again). A file
   * deleted meanwhile is discarded on the server. Once stored, the file itself is let go (a phone keeps no copy). */
  async function uploadOne(key: string) {
    const f = filesRef.current.find((x) => x.key === key);
    if (!f || !f.file || f.state === "stored") return;
    const file = f.file;
    patch(key, { state: "uploading", progress: 0, error: null });
    let uploadId = f.uploadId;
    try {
      const done = await storeFile({ uploadId: f.uploadId, path: f.path }, {
        begin: async () => {
          const draft = await ensureDraft();
          const r = await call("script_upload_begin", { p_submission: draft, p_kind: f.kind, p_mime: f.mime, p_bytes: f.size });
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
      }, (id, path) => {
        uploadId = id;
        if (!present(key)) return false;
        patch(key, { uploadId: id, path });
        return true;
      });
      if (!done || !present(key)) {
        if (uploadId) await call("script_upload_discard", { p_upload: uploadId });
        return;
      }
      patch(key, { state: "stored", progress: 1, file: null });
    } catch (e) {
      const code = e instanceof Error ? e.message : "internal";
      patch(key, { state: "failed", error: code === "unauthenticated" ? "Please sign in again." : uploadMessageFor(code) });
    }
  }

  function enqueue(key: string) {
    queue.current = queue.current.then(() => uploadOne(key)).catch(() => undefined);
  }

  /** Adds files (chosen, dropped or photographed); `replace` swaps one file of the strip for the first of them. */
  function addFiles(list: File[], opts: { replace?: string | null; checked?: boolean } = {}) {
    setNotice(null);
    const problems: string[] = [];
    const added: LocalFile[] = [];
    const room = MAX_FILES - filesRef.current.length + (opts.replace ? 1 : 0);
    for (const file of list) {
      const type = uploadFileType(file.name, file.type);
      const problem = type ? fileProblem(type.kind, file.size) : "wrong_file_type";
      if (!type || problem) {
        problems.push(`${file.name || "A file"}: ${uploadMessageFor(problem)}`);
        continue;
      }
      if (added.length >= room) {
        problems.push(uploadMessageFor("too_many_files"));
        break;
      }
      added.push({
        key: newKey(), uploadId: null, path: null, kind: type.kind, mime: type.mime, size: file.size, file,
        preview: null, state: "waiting", progress: 0, error: null, blurred: false,
      });
    }
    if (problems.length) setNotice(problems.join(" "));
    if (!added.length) return;
    setFiles((fs) => {
      if (!opts.replace) return [...fs, ...added];
      const at = fs.findIndex((x) => x.key === opts.replace);
      return at < 0 ? [...fs, ...added] : [...fs.slice(0, at), ...added, ...fs.slice(at)];
    });
    if (opts.replace) void remove(opts.replace);
    for (const a of added) {
      if (a.kind === "home_photo") inspect(a.key, a.file!, !opts.checked);
      enqueue(a.key);
    }
  }

  /** The photo's thumbnail and (unless the camera already asked) its blur check, one photo at a time. */
  function inspect(key: string, file: File, checkBlur: boolean) {
    inspecting.current = inspecting.current
      .then(async () => {
        if (!present(key)) return;
        const { score, thumbnail } = await inspectPhoto(file);
        if (!present(key)) return;
        patch(key, {
          preview: thumbnail ? URL.createObjectURL(thumbnail) : null,
          ...(checkBlur && score !== null && isBlurred(score) ? { blurred: true } : {}),
        });
      })
      .catch(() => undefined);
  }

  async function remove(key: string) {
    const f = filesRef.current.find((x) => x.key === key);
    if (!f) return;
    setFiles((fs) => fs.filter((x) => x.key !== key));
    if (f.preview) URL.revokeObjectURL(f.preview);
    if (f.uploadId) {
      const r = await call("script_upload_discard", { p_upload: f.uploadId });
      if (r.ok !== true) setNotice(uploadMessageFor(r.code));
    }
  }

  /** The server's order follows the strip once nothing is waiting to be begun. */
  async function syncOrder(): Promise<boolean> {
    const fs = filesRef.current;
    if (!draftRef.current || fs.some((f) => !f.uploadId)) return false;
    const r = await call("script_upload_reorder", { p_submission: draftRef.current, p_uploads: fs.map((f) => f.uploadId) });
    return r.ok === true;
  }

  function move(key: string, to: number) {
    setFiles((fs) => {
      const from = fs.findIndex((x) => x.key === key);
      if (from < 0 || to < 0 || to >= fs.length || from === to) return fs;
      const next = [...fs];
      const [item] = next.splice(from, 1);
      next.splice(to, 0, item);
      return next;
    });
    void syncOrder();
  }

  function retake(key: string) {
    if (phone) setCamera({ replace: key });
    else {
      replaceKey.current = key;
      replaceInput.current?.click();
    }
  }

  async function submit() {
    if (!draftRef.current || !canSubmit(filesRef.current)) return;
    setBusy("submit");
    setNotice(null);
    await syncOrder();
    const r = await call("home_submission_submit", { p_submission: draftRef.current });
    if (r.ok === true) {
      // The server's own answer shows at once ("Checking your pages", and the polling); never the earlier status.
      const result = r as unknown as SubmitResult;
      submittedSeq.current = result.seq;
      setStatus((s) => (s ? afterSubmit(s, result) : s));
      for (const f of filesRef.current) if (f.preview) URL.revokeObjectURL(f.preview);
      setFiles(() => []);
      draftRef.current = null;
      setEditing(false);
      focusNext.current = "status";
    } else setNotice(uploadMessageFor(r.code));
    await load();
    setBusy(null);
  }

  /** "Replace all pages" / "Replace some pages" (also "Retake page {n}" and "Add the page"): a draft that replaces
   * all pages or only those it shows, then the upload screen (the camera at once for a retake on a phone). */
  async function startReplacing(all: boolean, openCamera = false) {
    setBusy(all ? "replace-all" : "replace-some");
    setNotice(null);
    const r = await call("home_submission_open", { p_booking: bookingId, p_replaces_all: all });
    setBusy(null);
    if (r.ok !== true) {
      setNotice(uploadMessageFor(r.code));
      return;
    }
    draftRef.current = String(r.submission_id);
    setReplaceAll(Boolean(r.replaces_all));
    setEditing(true);
    if (openCamera && phone) setCamera({ replace: null });
    await load();
  }

  async function answer(name: string, args: Record<string, unknown>, key: string) {
    setBusy(key);
    setNotice(null);
    const r = await call(name, args);
    if (r.ok !== true) setNotice(uploadMessageFor(r.code));
    await load();
    setBusy(null);
  }

  function onDrop(e: DragEvent) {
    e.preventDefault();
    setDragOver(false);
    if (e.dataTransfer.files.length) addFiles(Array.from(e.dataTransfer.files));
  }

  if (!status) {
    return (
      <div data-testid="home-upload" className="space-y-2">
        <p data-testid="upload-live" role="status" aria-live="polite" className="sr-only" />
        {loadFailed && (
          <div role="alert" className="flex flex-wrap items-center gap-2 text-sm text-red-700">
            <span>{UPLOAD_TEXT.loadFailure}</span>
            <button type="button" className={SMALL} onClick={() => void load()}>{UPLOAD_TEXT.tryAgain}</button>
          </div>
        )}
      </div>
    );
  }

  const sub = status.submission;
  const word = statusWord(sub);
  const view = uploadView(status, { canUpload, editing });
  const showEditor = view.editor;
  const items = attentionItems(status);
  const uploadingCount = files.filter((f) => f.state === "waiting" || f.state === "uploading").length;
  const settled = sub && sub.state !== "checking";
  const replacing = !!sub;

  return (
    <div data-testid="home-upload" className="space-y-3">
      <p data-testid="upload-live" role="status" aria-live="polite" className="sr-only">
        {showEditor ? (uploadingCount ? `${UPLOAD_TEXT.uploading}: ${uploadingCount}` : "") : (word ?? "")}
      </p>

      {!showEditor && sub && (
        <div data-testid="upload-status" className="space-y-2 rounded-lg border border-slate-200 p-3">
          {word && (
            <h3 ref={statusHeading} tabIndex={-1} data-testid="upload-status-word" className="font-semibold text-slate-800 focus:outline-none">
              {word}
            </h3>
          )}
          {sub.state === "checking" && <p className="text-slate-600">{UPLOAD_TEXT.checkingHint}</p>}
          {sub.state === "rejected" && <p className="text-slate-700">{UPLOAD_TEXT.rejectedNote}</p>}
          {sub.late && sub.state !== "received" && <p className="text-amber-900">{UPLOAD_TEXT.lateNote}</p>}

          {sub.state === "needs_attention" && (
            items.length === 0 ? (
              <p className="text-slate-700">{UPLOAD_TEXT.attentionNone}</p>
            ) : (
              <ul data-testid="upload-attention" className="space-y-2">
                {items.map((it) => {
                  if (it.kind === "retake") {
                    return (
                      <li key={`r${it.pageId}`} className="space-y-1 rounded bg-amber-50 p-2">
                        <p className="text-slate-800">Page {it.page}: {it.reason}</p>
                        <div className="flex flex-wrap gap-2">
                          {canUpload && (
                            <button type="button" className={BUTTON} disabled={!!busy} onClick={() => void startReplacing(false, true)}>
                              {retakePrompt(it.page)}<span className="sr-only"> for {label}</span>
                            </button>
                          )}
                          <button type="button" className={QUIET} disabled={!!busy}
                            onClick={() => void answer("home_page_send_as_is", { p_page: it.pageId }, `as-is-${it.pageId}`)}>
                            {UPLOAD_TEXT.sendAsIs}<span className="sr-only">: page {it.page}, {label}</span>
                          </button>
                        </div>
                      </li>
                    );
                  }
                  if (it.kind === "missing") {
                    return (
                      <li key={`m${it.page}`} className="space-y-1 rounded bg-amber-50 p-2">
                        <p className="text-slate-800">{blankPrompt(it.page)}</p>
                        <div className="flex flex-wrap gap-2">
                          <button type="button" className={BUTTON} disabled={!!busy}
                            onClick={() => void answer("home_missing_confirm_blank", { p_submission: sub.id, p_pages: [it.page] }, `blank-${it.page}`)}>
                            {UPLOAD_TEXT.yes}<span className="sr-only">, page {it.page} was left blank ({label})</span>
                          </button>
                          {canUpload && (
                            <button type="button" className={QUIET} disabled={!!busy} onClick={() => void startReplacing(false, true)}>
                              {UPLOAD_TEXT.addPage}<span className="sr-only"> {it.page} for {label}</span>
                            </button>
                          )}
                        </div>
                      </li>
                    );
                  }
                  if (it.kind === "unplaced") {
                    const id = `place-${it.pageId}`;
                    const choice = placeChoice[it.pageId] ?? "";
                    return (
                      <li key={id} className="space-y-1 rounded bg-amber-50 p-2">
                        <p className="text-slate-800">A page without a code (file {it.file}, page {it.sourcePage}).</p>
                        <label htmlFor={id} className="block text-slate-700">{UPLOAD_TEXT.whichPage}</label>
                        <div className="flex flex-wrap gap-2">
                          <select id={id} value={choice} className="rounded border border-slate-300 px-2 py-1"
                            onChange={(e) => setPlaceChoice((c) => ({ ...c, [it.pageId]: e.target.value }))}>
                            <option value="">Choose a page</option>
                            {Array.from({ length: status.copy_pages ?? 0 }, (_, i) => i + 1).map((n) => (
                              <option key={n} value={n}>After page {n}</option>
                            ))}
                          </select>
                          <button type="button" className={BUTTON} disabled={!!busy || !choice}
                            onClick={() => void answer("home_page_place", { p_page: it.pageId, p_after_page: Number(choice) }, id)}>
                            {UPLOAD_TEXT.save}<span className="sr-only"> where this page goes ({label})</span>
                          </button>
                        </div>
                      </li>
                    );
                  }
                  return (
                    <li key={`f${it.file}`} className="rounded bg-amber-50 p-2 text-slate-800">
                      File {it.file} could not be read. Upload it again.
                    </li>
                  );
                })}
              </ul>
            )
          )}

          {view.receipt && sub.state === "received" && (
            <UploadReceipt label={label} scriptNumber={status.script?.number ?? null} seq={sub.seq} submittedAt={sub.submitted_at}
              pages={status.script?.pages ?? []} blank={status.blank} late={sub.late} />
          )}

          {canUpload && settled && (
            <div className="flex flex-wrap gap-2 print:hidden">
              {files.length > 0 && (
                <button type="button" className={BUTTON} onClick={() => setEditing(true)}>{UPLOAD_TEXT.continueDraft}</button>
              )}
              <button type="button" className={QUIET} disabled={!!busy} onClick={() => void startReplacing(true)}>
                {UPLOAD_TEXT.replaceAll}<span className="sr-only"> for {label}</span>
              </button>
              {sub.state !== "rejected" && (
                <button type="button" className={QUIET} disabled={!!busy} onClick={() => void startReplacing(false)}>
                  {UPLOAD_TEXT.replaceSome}<span className="sr-only"> for {label}</span>
                </button>
              )}
            </div>
          )}
        </div>
      )}

      {!canUpload && !sub && <p className="text-slate-700">{UPLOAD_TEXT.closed}</p>}

      {showEditor && (
        <div data-testid="upload-editor" className="space-y-3 rounded-lg border border-slate-200 p-3 print:hidden">
          {replacing && (
            <div className="flex flex-wrap items-center justify-between gap-2">
              <p className="font-semibold text-slate-800">{replaceAll ? UPLOAD_TEXT.replaceAll : UPLOAD_TEXT.replaceSome}</p>
              <button type="button" className={SMALL} onClick={() => setEditing(false)}>{UPLOAD_TEXT.back}</button>
            </div>
          )}
          {replacing && !replaceAll && <p className="text-slate-600">{UPLOAD_TEXT.replaceSomeHint}</p>}
          <p data-testid="upload-advice" className="text-slate-700">{UPLOAD_TEXT.photoAdvice}</p>

          {camera ? (
            <CameraCapture label={label} single={camera.replace !== null}
              onCapture={(file) => addFiles([file], { replace: camera.replace, checked: true })}
              onClose={() => {
                setCamera(null);
                focusNext.current = "photograph";
              }} />
          ) : (
            <div className="space-y-2">
              {phone && (
                <button ref={photographButton} type="button" className={BUTTON} onClick={() => setCamera({ replace: null })}>
                  {UPLOAD_TEXT.photograph}<span className="sr-only"> for {label}</span>
                </button>
              )}
              <div data-testid="upload-drop"
                onDragOver={(e) => {
                  e.preventDefault();
                  setDragOver(true);
                }}
                onDragLeave={() => setDragOver(false)}
                onDrop={onDrop}
                className={`rounded-lg border-2 border-dashed p-4 text-center ${dragOver ? "border-blue-500 bg-blue-50" : "border-slate-300"}`}>
                <p className="font-semibold text-slate-800">{UPLOAD_TEXT.dropZone}</p>
                {!phone && <p className="text-sm text-slate-600">{UPLOAD_TEXT.dropHint}</p>}
                <label className={`${QUIET} ${FOCUS_WITHIN} mt-2 inline-block cursor-pointer`}>
                  {UPLOAD_TEXT.chooseFiles}<span className="sr-only"> for {label}</span>
                  <input type="file" multiple accept={ACCEPT} className="sr-only"
                    onChange={(e) => {
                      addFiles(Array.from(e.currentTarget.files ?? []));
                      e.currentTarget.value = "";
                    }} />
                </label>
              </div>
            </div>
          )}
          <input ref={replaceInput} type="file" accept={ACCEPT} className="hidden" aria-hidden="true" tabIndex={-1}
            onChange={(e) => {
              addFiles(Array.from(e.currentTarget.files ?? []).slice(0, 1), { replace: replaceKey.current });
              replaceKey.current = null;
              e.currentTarget.value = "";
            }} />

          {files.length > 0 && (
            <>
              <p className="text-sm text-slate-600">{files.length} of {MAX_FILES} files</p>
              <ol data-testid="upload-files" className="flex flex-wrap gap-2">
                {files.map((f, i) => (
                  <li key={f.key} draggable
                    onDragStart={() => setDragKey(f.key)}
                    onDragOver={(e) => e.preventDefault()}
                    onDrop={(e) => {
                      e.preventDefault();
                      e.stopPropagation();
                      if (dragKey) move(dragKey, i);
                      setDragKey(null);
                    }}
                    className="w-36 space-y-1 rounded border border-slate-200 bg-white p-1.5 text-xs">
                    <div className="flex h-28 items-center justify-center overflow-hidden rounded bg-slate-100">
                      {f.preview ? (
                        // eslint-disable-next-line @next/next/no-img-element -- a local photo before it is uploaded
                        <img src={f.preview} alt={`File ${i + 1}`} className="h-full w-full object-cover" />
                      ) : (
                        <span className="font-semibold text-slate-600">{f.kind === "home_pdf" ? "PDF" : "Photo"} {i + 1}</span>
                      )}
                    </div>
                    {f.state === "uploading" || f.state === "waiting" ? (
                      <div>
                        <p>{UPLOAD_TEXT.uploading} {Math.round(f.progress * 100)}%</p>
                        <div role="progressbar" aria-label={`File ${i + 1}`} aria-valuemin={0} aria-valuemax={100}
                          aria-valuenow={Math.round(f.progress * 100)} className="h-1.5 rounded bg-slate-200">
                          <div className="h-1.5 rounded bg-blue-600" style={{ width: `${Math.round(f.progress * 100)}%` }} />
                        </div>
                      </div>
                    ) : f.state === "stored" ? (
                      <p className="text-green-800">{UPLOAD_TEXT.uploaded}</p>
                    ) : f.state === "elsewhere" ? (
                      <p className="text-slate-600">{UPLOAD_TEXT.elsewhere}</p>
                    ) : (
                      <p role="alert" className="text-red-700">{f.error}</p>
                    )}
                    {f.blurred && (
                      <div className="space-y-1 rounded bg-amber-50 p-1">
                        <p className="text-amber-900">{UPLOAD_TEXT.blurred}</p>
                        <div className="flex gap-1">
                          <button type="button" className={SMALL} onClick={() => retake(f.key)}>{UPLOAD_TEXT.retake}</button>
                          <button type="button" className={SMALL} onClick={() => patch(f.key, { blurred: false })}>{UPLOAD_TEXT.keep}</button>
                        </div>
                      </div>
                    )}
                    <div className="flex flex-wrap gap-1">
                      {f.state === "failed" && f.file && (
                        <button type="button" className={SMALL} onClick={() => enqueue(f.key)}>{UPLOAD_TEXT.tryAgain}</button>
                      )}
                      {f.kind === "home_photo" && !f.blurred && (
                        <button type="button" className={SMALL} onClick={() => retake(f.key)}>
                          {UPLOAD_TEXT.retake}<span className="sr-only"> file {i + 1}</span>
                        </button>
                      )}
                      <button type="button" className={SMALL} aria-label={`Move file ${i + 1} earlier`} disabled={i === 0} onClick={() => move(f.key, i - 1)}>←</button>
                      <button type="button" className={SMALL} aria-label={`Move file ${i + 1} later`} disabled={i === files.length - 1} onClick={() => move(f.key, i + 1)}>→</button>
                      <button type="button" className={SMALL} onClick={() => void remove(f.key)}>
                        {UPLOAD_TEXT.remove}<span className="sr-only"> file {i + 1}</span>
                      </button>
                    </div>
                  </li>
                ))}
              </ol>
            </>
          )}

          <div className="space-y-1">
            <button type="button" className={BUTTON} disabled={!!busy || !canSubmit(files)} onClick={() => void submit()}>
              {UPLOAD_TEXT.submit}<span className="sr-only"> the answers for {label}</span>
            </button>
            <p className="text-sm text-slate-600">{UPLOAD_TEXT.submitHint}</p>
          </div>
        </div>
      )}

      {notice && <p role="alert" className="text-sm text-red-700">{notice}</p>}
      {loadFailed && (
        <div role="alert" className="flex flex-wrap items-center gap-2 text-sm text-red-700">
          <span>{UPLOAD_TEXT.loadFailure}</span>
          <button type="button" className={SMALL} onClick={() => void load()}>{UPLOAD_TEXT.tryAgain}</button>
        </div>
      )}
    </div>
  );
}
