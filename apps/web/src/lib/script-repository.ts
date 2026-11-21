/** The script repository: what scripts_list and script_detail answer, the words staff read for a script's state, what
 * staff may still do to it, and the calls the page tools make. The database checks every rule again. */
import { scriptMessageFor } from "@stem/shared";
import { parseQueueItem, type QueueArea, type QueueItem } from "./exception-queue";
import { isUuid } from "./uuid";

export const SCRIPT_STATES = [
  "receiving",
  "checking",
  "needs_attention",
  "verified",
  "ready_to_mark",
  "marking",
  "marked",
  "checked",
  "final",
  "withdrawn",
  "void",
] as const;
export type ScriptState = (typeof SCRIPT_STATES)[number];
export type ScriptSource = "home" | "centre";

export const STATE_LABEL: Record<ScriptState, string> = {
  receiving: "Receiving",
  checking: "Checking",
  needs_attention: "Needs attention",
  verified: "Verified",
  ready_to_mark: "Ready to mark",
  marking: "Being marked",
  marked: "Marked",
  checked: "Checked",
  final: "Final",
  withdrawn: "Withdrawn",
  void: "Void",
};

export const STATE_TONE: Record<ScriptState, "blue" | "green" | "amber" | "red" | "slate"> = {
  receiving: "blue",
  checking: "blue",
  needs_attention: "amber",
  verified: "green",
  ready_to_mark: "green",
  marking: "green",
  marked: "green",
  checked: "green",
  final: "green",
  withdrawn: "slate",
  void: "red",
};

const REASON_WORDS: Record<string, string> = {
  voided: "voided by staff",
  late_rejected: "late script not marked",
  booking_cancelled: "booking cancelled",
  booking_refunded: "booking refunded",
  booking_expired: "booking expired",
};

export const SOURCE_LABEL: Record<ScriptSource, string> = { home: "Home", centre: "Centre" };

/** "Withdrawn (booking cancelled)", "Verified". */
export function stateText(state: ScriptState, reason: string | null): string {
  const why = reason ? (REASON_WORDS[reason] ?? null) : null;
  return why ? `${STATE_LABEL[state]} (${why})` : STATE_LABEL[state];
}

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const numbers = (v: unknown): number[] => (Array.isArray(v) ? v.filter((x): x is number => typeof x === "number" && Number.isFinite(x)) : []);
const isState = (v: unknown): v is ScriptState => typeof v === "string" && (SCRIPT_STATES as readonly string[]).includes(v);
const isSource = (v: unknown): v is ScriptSource => v === "home" || v === "centre";

export type ScriptExam = { id: string; title: string; paper: string; code: string | null };
export type Candidate = { name: string | null; indexNumber: string | null };

function parseExam(v: unknown): ScriptExam | null {
  if (!isObject(v) || !str(v.id)) return null;
  return { id: str(v.id)!, title: str(v.title) ?? "", paper: str(v.paper) ?? "", code: str(v.code) };
}

function parseCandidate(v: unknown): Candidate {
  return isObject(v) ? { name: str(v.name), indexNumber: str(v.index_number) } : { name: null, indexNumber: null };
}

/** The candidate as staff read them: "Sam One (SE-2097-6601)". */
export function candidateText(c: Candidate): string {
  const name = c.name ?? "Removed account";
  return c.indexNumber ? `${name} (${c.indexNumber})` : name;
}

// ---------------------------------------------------------------------------------------------------------------
// The list.
// ---------------------------------------------------------------------------------------------------------------

export type ScriptListItem = {
  id: string;
  number: string;
  bookingId: string | null;
  source: ScriptSource;
  state: ScriptState;
  stateReason: string | null;
  late: boolean;
  lateDecision: string | null;
  complete: boolean;
  version: number;
  pages: number;
  extraPages: number;
  openExceptions: number;
  receivedAt: string | null;
  createdAt: string | null;
  exam: ScriptExam | null;
  candidate: Candidate;
};

function parseListItem(v: unknown): ScriptListItem | null {
  if (!isObject(v) || !str(v.id) || !str(v.number) || !isSource(v.source) || !isState(v.state)) return null;
  return {
    id: str(v.id)!,
    number: str(v.number)!,
    bookingId: str(v.booking_id),
    source: v.source,
    state: v.state,
    stateReason: str(v.state_reason),
    late: v.late === true,
    lateDecision: str(v.late_decision),
    complete: v.complete === true,
    version: num(v.version) ?? 0,
    pages: num(v.pages) ?? 0,
    extraPages: num(v.extra_pages) ?? 0,
    openExceptions: num(v.open_exceptions) ?? 0,
    receivedAt: str(v.received_at),
    createdAt: str(v.created_at),
    exam: parseExam(v.exam),
    candidate: parseCandidate(v.candidate),
  };
}

/** scripts_list's answer, or null for a failure. Malformed items are left out. */
export function parseScriptList(data: unknown): { items: ScriptListItem[]; more: boolean } | null {
  if (!isObject(data) || data.ok !== true || !Array.isArray(data.items)) return null;
  return { items: data.items.map(parseListItem).filter((i): i is ScriptListItem => i !== null), more: data.more === true };
}

export type ScriptFilters = { exam: string; source: ScriptSource | null; state: ScriptState | null; late: boolean | null };
type Params = Record<string, string | string[] | undefined>;
const first = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v) ?? "";

/** The list's filters from the address (anything else is ignored): exam (a uuid), source, state, late (yes or no). */
export function parseFilters(p: Params): ScriptFilters {
  const exam = first(p.exam);
  const source = first(p.source);
  const state = first(p.state);
  const late = first(p.late);
  return {
    exam: isUuid(exam) ? exam : "",
    source: isSource(source) ? source : null,
    state: isState(state) ? state : null,
    late: late === "yes" ? true : late === "no" ? false : null,
  };
}

/** scripts_list's arguments for the filters (unset filters are left out). */
export function listArgs(f: ScriptFilters): { p_exam?: string; p_source?: ScriptSource; p_state?: ScriptState; p_late?: boolean } {
  return {
    ...(f.exam ? { p_exam: f.exam } : {}),
    ...(f.source ? { p_source: f.source } : {}),
    ...(f.state ? { p_state: f.state } : {}),
    ...(f.late !== null ? { p_late: f.late } : {}),
  };
}

// ---------------------------------------------------------------------------------------------------------------
// The detail.
// ---------------------------------------------------------------------------------------------------------------

export type DetailPage = {
  pageId: string;
  /** The copy page the script shows it at (null: an extra page the family placed). */
  copyPage: number | null;
  /** The copy page its code says (null: no code). */
  printedPage: number | null;
  placedAfter: number | null;
  extra: boolean;
  role: string | null;
  fullPath: string;
  markingPath: string | null;
  rotation: number;
  /** The quarter turn staff gave the page since its full picture was made (the marking picture is turned so). */
  turn: number;
  uploadId: string | null;
  sourceIndex: number | null;
  state: string;
  flags: string[];
  paperVersion: number | null;
  /** Staff hidden areas, as fractions of the full picture. */
  areas: QueueArea[];
};

export type DetailVersion = { version: number; createdAt: string | null; reason: string | null; by: string | null; submissionSeq: number | null; pages: number[] };
export type DetailJob = { id: number; kind: string; state: string; attempts: number; lastError: string | null; createdAt: string | null; finishedAt: string | null };
export type DetailUpload = {
  id: string;
  kind: string;
  state: string;
  source: ScriptSource;
  position: number | null;
  batchNumber: string | null;
  submissionSeq: number | null;
  submissionState: string | null;
  createdAt: string | null;
  pages: number;
  jobs: DetailJob[];
};
export type CustodyEvent = { step: string; at: string | null; location: string; note: string | null; manifest: string | null; byName: string | null; fromName: string | null; toName: string | null };
export type ActionRow = { action: string; at: string | null; by: string | null; reason: string | null };

export type ScriptDetail = {
  script: {
    id: string;
    number: string;
    source: ScriptSource;
    state: ScriptState;
    stateReason: string | null;
    version: number;
    complete: boolean;
    late: boolean;
    lateDecision: string | null;
    receivedAt: string | null;
    createdAt: string | null;
    exam: ScriptExam | null;
    bookingStatus: string | null;
  };
  candidate: Candidate;
  versions: DetailVersion[];
  pages: DetailPage[];
  uploads: DetailUpload[];
  exceptions: QueueItem[];
  custody: CustodyEvent[];
  actions: ActionRow[];
};

function parseArea(v: unknown): QueueArea | null {
  if (!isObject(v)) return null;
  const x = num(v.x), y = num(v.y), w = num(v.w), h = num(v.h);
  return x === null || y === null || w === null || h === null ? null : { x, y, w, h };
}

function parseDetailPage(v: unknown): DetailPage | null {
  if (!isObject(v)) return null;
  const pageId = str(v.page_id) ?? str(v.id);
  const fullPath = str(v.full_path);
  if (!pageId || !fullPath) return null;
  const quality = isObject(v.quality) ? v.quality : {};
  return {
    pageId,
    copyPage: num(v.copy_page),
    printedPage: num(v.printed_page),
    placedAfter: num(v.placed_after),
    extra: v.extra === true,
    role: str(v.role),
    fullPath,
    markingPath: str(v.marking_path),
    rotation: num(v.rotation) ?? 0,
    turn: num(v.turn) ?? 0,
    uploadId: str(v.upload_id),
    sourceIndex: num(v.source_index),
    state: str(v.state) ?? "",
    flags: Array.isArray(quality.flags) ? quality.flags.filter((f): f is string => typeof f === "string") : [],
    paperVersion: num(v.paper_version),
    areas: Array.isArray(v.areas) ? v.areas.map(parseArea).filter((a): a is QueueArea => a !== null) : [],
  };
}

function parseUpload(v: unknown): DetailUpload | null {
  if (!isObject(v) || !str(v.id)) return null;
  return {
    id: str(v.id)!,
    kind: str(v.kind) ?? "",
    state: str(v.state) ?? "",
    source: v.source === "home" ? "home" : "centre",
    position: num(v.position),
    batchNumber: str(v.batch_number),
    submissionSeq: num(v.submission_seq),
    submissionState: str(v.submission_state),
    createdAt: str(v.created_at),
    pages: num(v.pages) ?? 0,
    jobs: Array.isArray(v.jobs)
      ? v.jobs.flatMap((j): DetailJob[] =>
          isObject(j) && num(j.id) !== null
            ? [{ id: num(j.id)!, kind: str(j.kind) ?? "", state: str(j.state) ?? "", attempts: num(j.attempts) ?? 0, lastError: str(j.last_error), createdAt: str(j.created_at), finishedAt: str(j.finished_at) }]
            : [],
        )
      : [],
  };
}

const list = <T,>(v: unknown, parse: (x: unknown) => T | null): T[] => (Array.isArray(v) ? v.map(parse).filter((x): x is T => x !== null) : []);

/** script_detail's answer, or null for a failure or an answer that is not one. */
export function parseScriptDetail(data: unknown): ScriptDetail | null {
  if (!isObject(data) || data.ok !== true || !isObject(data.script)) return null;
  const s = data.script;
  if (!str(s.id) || !str(s.number) || !isSource(s.source) || !isState(s.state)) return null;
  return {
    script: {
      id: str(s.id)!,
      number: str(s.number)!,
      source: s.source,
      state: s.state,
      stateReason: str(s.state_reason),
      version: num(s.version) ?? 0,
      complete: s.complete === true,
      late: s.late === true,
      lateDecision: str(s.late_decision),
      receivedAt: str(s.received_at),
      createdAt: str(s.created_at),
      exam: parseExam(s.exam),
      bookingStatus: isObject(s.booking) ? str(s.booking.status) : null,
    },
    candidate: parseCandidate(data.candidate),
    versions: list(data.versions, (v) =>
      isObject(v) && num(v.version) !== null
        ? { version: num(v.version)!, createdAt: str(v.created_at), reason: str(v.reason), by: str(v.by), submissionSeq: num(v.submission_seq), pages: numbers(v.pages) }
        : null,
    ),
    pages: list(data.pages, parseDetailPage),
    uploads: list(data.uploads, parseUpload),
    exceptions: list(data.exceptions, parseQueueItem),
    custody: list(data.custody, (v) =>
      isObject(v) && str(v.step)
        ? { step: str(v.step)!, at: str(v.at), location: str(v.location) ?? "", note: str(v.note), manifest: str(v.manifest), byName: str(v.by_name), fromName: str(v.from_name), toName: str(v.to_name) }
        : null,
    ),
    actions: list(data.actions, (v) => (isObject(v) && str(v.action) ? { action: str(v.action)!, at: str(v.at), by: str(v.by), reason: str(v.reason) } : null)),
  };
}

export const ROLE_LABEL: Record<string, string> = {
  answer: "Answer page",
  cover: "Cover",
  blank: "Blank page",
  information: "Information",
  spare: "Spare page",
  extra: "Extra page",
};

/** "Page 3", or "Extra page after page 2" for a page the family added. */
export function pageLabel(p: DetailPage): string {
  if (p.extra) return p.placedAfter !== null ? `Extra page after page ${p.placedAfter}` : "Extra page";
  return p.copyPage !== null ? `Page ${p.copyPage}` : "Page";
}

/** The marking picture's turn in words ("" when not turned). */
export function turnText(turn: number): string {
  switch (turn) {
    case 90:
      return "Turned a quarter turn right for marking.";
    case 180:
      return "Turned a half turn for marking.";
    case 270:
      return "Turned a quarter turn left for marking.";
    default:
      return "";
  }
}

const VERSION_REASONS: Record<string, string> = {
  home_submission: "Handed in from home",
  scan_upload: "Scanned at the centre",
  reprocessed: "File processed again",
  staff_assign: "Page assigned by staff",
  staff_set_aside: "Page set aside by staff",
  submission_rejected: "Submission rejected",
};
export const versionReason = (r: string | null) => (r ? (VERSION_REASONS[r] ?? r) : "");

const ACTION_WORDS: Record<string, string> = {
  script_page_rotated: "Page turned",
  script_upload_reprocess: "File processed again",
  script_voided: "Script voided",
  script_page_removed: "Page removed from the script",
  script_page_hidden_areas_set: "Name hidden on a page",
  script_late_accepted: "Late script accepted",
  script_late_rejected: "Late script not marked",
};
export const actionText = (a: string) => ACTION_WORDS[a] ?? a.replace(/^script_/, "").replace(/_/g, " ");

const JOB_STATE: Record<string, string> = { queued: "waiting", running: "running", done: "done", failed: "failed" };
/** "Marking pictures: waiting", "Preparing: failed after 3 attempts". */
export function jobText(j: DetailJob): string {
  const what = j.kind === "remask" ? "Marking pictures" : "Preparing";
  const state = JOB_STATE[j.state] ?? j.state;
  return j.state === "failed" ? `${what}: failed after ${j.attempts} attempts` : `${what}: ${state}`;
}

const BEFORE_MARKING: readonly ScriptState[] = ["receiving", "checking", "needs_attention", "verified"];
const MARKING: readonly ScriptState[] = ["ready_to_mark", "marking", "marked", "checked", "final"];

/** Whether staff may still change the script's pages (turn, remove): only before marking. */
export const pagesEditable = (s: ScriptState) => BEFORE_MARKING.includes(s);
/** Whether staff may void the script: any that is not final, nor void already. */
export const voidable = (s: ScriptState) => s !== "final" && s !== "void";
/** Whether a marking picture of the file is waiting to be made, or being made. */
export const remaskPending = (u: DetailUpload) => u.jobs.some((j) => j.kind === "remask" && (j.state === "queued" || j.state === "running"));
/** Whether the file may be processed again: processed or failed, while the script is not being marked. */
export const reprocessable = (u: DetailUpload, s: ScriptState) => (u.state === "processed" || u.state === "failed") && !MARKING.includes(s);

// ---------------------------------------------------------------------------------------------------------------
// The page tools.
// ---------------------------------------------------------------------------------------------------------------

export type RepoInput =
  | { action: "rotate"; pageId: string; turns: 1 | -1 | 2; reason: string }
  | { action: "reprocess"; uploadId: string; reason: string }
  | { action: "void"; reason: string }
  | { action: "remove"; copyPage: number; reason: string };

/** The database function a page tool calls, with its arguments. */
export function repoRpc(scriptId: string, input: RepoInput): { fn: string; args: Record<string, unknown> } {
  const reason = input.reason.trim();
  switch (input.action) {
    case "rotate":
      return { fn: "script_page_rotate", args: { p_page: input.pageId, p_quarter_turns: input.turns, p_reason: reason } };
    case "reprocess":
      return { fn: "script_upload_reprocess", args: { p_upload: input.uploadId, p_reason: reason } };
    case "void":
      return { fn: "script_void", args: { p_script: scriptId, p_reason: reason } };
    case "remove":
      return { fn: "script_page_remove", args: { p_script: scriptId, p_copy_page: input.copyPage, p_reason: reason } };
  }
}

/** What the screen says after a page tool did its work. */
export function repoDoneMessage(input: RepoInput): string {
  switch (input.action) {
    case "rotate":
      return "The page is turned. Its marking picture is being made again.";
    case "reprocess":
      return "The file will be processed again. Its pages are replaced when that is done.";
    case "void":
      return "The script is void. It will not be marked.";
    case "remove":
      return `Page ${input.copyPage} is taken out of the script (a new version). The page itself is kept.`;
  }
}

/** What the screen says when a page tool was refused (`action`: the tool, for a message that fits it). */
export function repoFailureMessage(a: { code?: unknown; reason?: unknown }, action?: RepoInput["action"]): string {
  if (action === "void" && a.code === "script_locked") return "This script is final: its results are out, so it cannot be voided.";
  return scriptMessageFor(typeof a.code === "string" ? a.code : null, typeof a.reason === "string" ? a.reason : null);
}
