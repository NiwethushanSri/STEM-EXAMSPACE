/** Scan batches (centre scripts from the office scanner): what the batch screen reads and checks in the browser.
 * The database re-checks every rule (scan_upload_begin, script_upload_stored). */

/** The batch screen asks for the totals again this often while a job waits or runs. */
export const SCAN_POLL_MS = 3000;
/** The largest scanner file: 1 GiB, as the bucket and scan_upload_begin allow. */
export const SCAN_MAX_BYTES = 1073741824;
/** What the file picker offers. */
export const SCAN_ACCEPT = ".pdf,.jpg,.jpeg,.png,application/pdf,image/jpeg,image/png";

export type ScanTotals = { pages: number; matched: number; blank: number; flagged: number; duplicates: number };
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

export type CompleteResult = { candidates: number; complete: number; missing: number };

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
    totals: { pages: count(totals.pages), matched: count(totals.matched), blank: count(totals.blank), flagged: count(totals.flagged), duplicates: count(totals.duplicates) },
    jobs: { queued: count(jobs.queued), running: count(jobs.running), failed: count(jobs.failed) },
    candidatesComplete: count(data.candidates_complete),
    candidatesExpected: count(data.candidates_expected),
  };
}

/** A job of the batch is waiting or running: the totals are still changing. */
export function isProcessing(s: ScanBatchStatus): boolean {
  return s.jobs.queued + s.jobs.running > 0;
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

/** "12 pages: 7 matched, 1 blank, 4 flagged, 1 duplicate" */
export function totalsLine(t: ScanTotals): string {
  return `${plural(t.pages, "page", "pages")}: ${t.matched} matched, ${t.blank} blank, ${t.flagged} flagged, ${plural(t.duplicates, "duplicate", "duplicates")}`;
}

/** scan_centre_complete's counts, or null for a failure. */
export function parseCompleteResult(data: unknown): CompleteResult | null {
  if (!isObject(data) || data.ok !== true) return null;
  return { candidates: count(data.candidates), complete: count(data.complete), missing: count(data.missing) };
}

/** What staff read after "All scans for this centre are uploaded". */
export function completeSummary(r: CompleteResult): string {
  if (r.candidates === 0) return "No candidate was marked present or late at this centre.";
  const head = `${plural(r.candidates, "candidate", "candidates")}: ${r.complete} complete`;
  return r.missing > 0 ? `${head}, ${r.missing} with missing pages. The missing pages are in the exception queue.` : `${head}.`;
}

/** "1.2 GB", "340 MB", "12 KB" */
export function fileSize(bytes: number): string {
  if (bytes >= 1024 ** 3) return `${(bytes / 1024 ** 3).toFixed(1)} GB`;
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(bytes / 1024))} KB`;
}
