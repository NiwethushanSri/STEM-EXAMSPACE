/** Scan batches (centre scripts from the office scanner): what the batch screen reads and checks in the browser.
 * The database re-checks every rule (scan_upload_begin, script_upload_stored). */
import { scanMessageFor } from "@stem/shared";

/** The batch screen asks for the totals again this often while a job waits or runs. */
export const SCAN_POLL_MS = 3000;
/** After this many failed polls in a row the screen stops asking and offers to try again. */
export const SCAN_POLL_MAX_FAILURES = 3;
/** The largest scanner file: 1 GiB, as the bucket and scan_upload_begin allow. */
export const SCAN_MAX_BYTES = 1073741824;
/** What the file picker offers. */
export const SCAN_ACCEPT = ".pdf,.jpg,.jpeg,.png,application/pdf,image/jpeg,image/png";

/** Each current page counted once (pages = matched + blank + flagged + duplicates + setAside): flagged pages have an
 * open exception; set-aside pages had one that staff dealt with. accepted: the centre's verified scripts. */
export type ScanTotals = {
  pages: number;
  matched: number;
  blank: number;
  flagged: number;
  duplicates: number;
  setAside: number;
  accepted: number;
};
export type ScanJobs = { queued: number; running: number; failed: number };
export type ScanUpload = { id: string; state: string; byteSize: number };

export type ScanBatchStatus = {
  id: string;
  number: string;
  centreId: string;
  /** The collection manifest's number, or null when none was named. */
  manifest: string | null;
  createdAt: string;
  /** When "Start processing" was pressed; null while files can still be added. */
  submittedAt: string | null;
  uploads: ScanUpload[];
  totals: ScanTotals;
  jobs: ScanJobs;
  /** Present or late candidates of the centre whose script is complete, and how many there are. */
  candidatesComplete: number;
  candidatesExpected: number;
};

/** missing: candidates with missing pages (or no paper known); mixed: candidates whose pages are of two paper versions. */
export type CompleteResult = { candidates: number; complete: number; missing: number; mixed: number };

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const count = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : 0);
const text = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/** scan_batch_status's answer, or null for a failure or an answer that is not one. */
export function parseScanStatus(data: unknown): ScanBatchStatus | null {
  if (!isObject(data) || data.ok !== true) return null;
  const id = text(data.batch_id);
  const number = text(data.number);
  const centreId = text(data.centre_id);
  const createdAt = text(data.created_at);
  if (!id || !number || !centreId || !createdAt) return null;
  const totals = isObject(data.totals) ? data.totals : {};
  const jobs = isObject(data.jobs) ? data.jobs : {};
  const uploads: ScanUpload[] = [];
  for (const u of Array.isArray(data.uploads) ? data.uploads : []) {
    if (isObject(u) && typeof u.id === "string" && typeof u.state === "string") uploads.push({ id: u.id, state: u.state, byteSize: count(u.byte_size) });
  }
  return {
    id,
    number,
    centreId,
    manifest: text(data.manifest),
    createdAt,
    submittedAt: text(data.submitted_at),
    uploads,
    totals: {
      pages: count(totals.pages),
      matched: count(totals.matched),
      blank: count(totals.blank),
      flagged: count(totals.flagged),
      duplicates: count(totals.duplicates),
      setAside: count(totals.set_aside),
      accepted: count(totals.accepted),
    },
    jobs: { queued: count(jobs.queued), running: count(jobs.running), failed: count(jobs.failed) },
    candidatesComplete: count(data.candidates_complete),
    candidatesExpected: count(data.candidates_expected),
  };
}

/** A job of the batch is waiting or running: the totals are still changing. */
export function isProcessing(s: ScanBatchStatus): boolean {
  return s.jobs.queued + s.jobs.running > 0;
}

/** A file of these batches is still waiting or uploading in this browser. */
export function hasUploadsInFlight(files: { batchId: string; state: string }[], batchIds: string[]): boolean {
  return files.some((f) => batchIds.includes(f.batchId) && (f.state === "waiting" || f.state === "uploading"));
}

const BY_EXT: Record<string, string> = { pdf: "application/pdf", jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png" };
const TYPES = new Set(Object.values(BY_EXT));

/** The type a scanner file is uploaded as (PDF, JPEG or PNG), from the browser's type or else the name; null when it
 * is neither. A file whose browser type is something else is refused. */
export function scanFileType(name: string, type: string): string | null {
  const t = (type || "").toLowerCase();
  if (t) return TYPES.has(t) ? t : null;
  const ext = (name.split(".").pop() ?? "").toLowerCase();
  return Object.hasOwn(BY_EXT, ext) ? BY_EXT[ext] : null;
}

/** Why a file of this size cannot be a scan (a code for scanMessageFor), or null. */
export function scanFileProblem(size: number): "file_too_large" | "invalid_input" | null {
  if (!(size > 0)) return "invalid_input";
  return size > SCAN_MAX_BYTES ? "file_too_large" : null;
}

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/** "12 pages: 6 matched, 1 blank, 1 duplicate, 3 to check, 1 set aside": each page once, so the numbers add up. */
export function totalsLine(t: ScanTotals): string {
  const aside = t.setAside > 0 ? `, ${t.setAside} set aside` : "";
  return `${plural(t.pages, "page", "pages")}: ${t.matched} matched, ${t.blank} blank, ${plural(t.duplicates, "duplicate", "duplicates")}, ${t.flagged} to check${aside}`;
}

/** scan_centre_complete's counts, or null for a failure. */
export function parseCompleteResult(data: unknown): CompleteResult | null {
  if (!isObject(data) || data.ok !== true) return null;
  return { candidates: count(data.candidates), complete: count(data.complete), missing: count(data.missing), mixed: count(data.mixed) };
}

/** What staff read after "All scans for this centre are uploaded". */
export function completeSummary(r: CompleteResult): string {
  if (r.candidates === 0) return "No candidate was marked present or late at this centre.";
  const parts = [`${plural(r.candidates, "candidate", "candidates")}: ${r.complete} complete`];
  if (r.missing > 0) parts.push(`${r.missing} with missing pages`);
  if (r.mixed > 0) parts.push(`${r.mixed} with pages from two paper versions`);
  return parts.length > 1 ? `${parts.join(", ")}. These are in the exception queue.` : `${parts[0]}.`;
}

/** Why "All scans for this centre are uploaded" was refused; the register asks for every candidate to be marked. */
export function completeFailureMessage(data: unknown): string {
  const code = isObject(data) && typeof data.code === "string" ? data.code : null;
  if (code === "register_incomplete") {
    const n = isObject(data) && typeof data.not_marked === "number" ? data.not_marked : null;
    return n === null ? "Mark every candidate on the register first." : `Mark every candidate on the register first (${n} not marked).`;
  }
  return scanMessageFor(code, "complete");
}

/**
 * Asks tick() every intervalMs, one at a time: the next ask is timed from the end of the last one, so two never
 * overlap. tick() answers whether it worked (a thrown error is a failure); after maxFailures failures in a row the
 * polling stops and onGiveUp is called. Returns stop(); an answer that arrives after stop() changes nothing.
 */
export function startPolling(
  tick: () => Promise<boolean>,
  opts: { intervalMs: number; maxFailures: number; onGiveUp: () => void },
): () => void {
  let stopped = false;
  let failures = 0;
  let timer: ReturnType<typeof setTimeout> | null = null;
  const run = async () => {
    timer = null;
    let ok = false;
    try {
      ok = await tick();
    } catch {
      ok = false;
    }
    if (stopped) return;
    failures = ok ? 0 : failures + 1;
    if (failures >= opts.maxFailures) {
      stopped = true;
      opts.onGiveUp();
      return;
    }
    timer = setTimeout(run, opts.intervalMs);
  };
  timer = setTimeout(run, opts.intervalMs);
  return () => {
    stopped = true;
    if (timer) clearTimeout(timer);
  };
}

/** "1.2 GB", "340 MB", "12 KB" */
export function fileSize(bytes: number): string {
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}
