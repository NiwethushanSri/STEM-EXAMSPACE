/** The exception queue: what script_exceptions_list answers, the plain words staff read for each problem, which
 * actions fit it, and the calls those actions make. The database checks every rule again. */
import { formatLondon } from "./money";

export const EXCEPTION_KINDS = [
  "no_code",
  "unknown_code",
  "other_exam",
  "not_expected",
  "duplicate",
  "missing_pages",
  "uncoded_family_page",
  "mixed_versions",
  "poor_quality",
  "late",
  "name_visible",
  "processing_failed",
] as const;
export type ExceptionKind = (typeof EXCEPTION_KINDS)[number];

export const KIND_LABEL: Record<ExceptionKind, string> = {
  no_code: "No code",
  unknown_code: "Unknown code",
  other_exam: "Another exam's page",
  not_expected: "Unexpected page",
  duplicate: "Duplicate page",
  missing_pages: "Missing pages",
  uncoded_family_page: "Page added by the family",
  mixed_versions: "Two paper versions",
  poor_quality: "Poor quality",
  late: "Handed in late",
  name_visible: "Name visible",
  processing_failed: "File not processed",
};

/** A rectangle as a fraction (0 to 1) of the full page picture, from its top left. */
export type QueueArea = { x: number; y: number; w: number; h: number };

export type QueuePage = {
  id: string;
  uploadId: string | null;
  sourceIndex: number | null;
  copyPage: number | null;
  state: string;
  blank: boolean;
  flags: string[];
  rotation: number;
  fullPath: string;
  markingPath: string | null;
  placedAfter: number | null;
  replaced: boolean;
  /** The paper version the page was printed from (null: no code). */
  paperVersion: number | null;
  paperCurrent: boolean | null;
  /** Staff hidden areas drawn on this page. */
  areas: QueueArea[];
};

export type QueueBooking = { id: string; name: string | null; indexNumber: string | null; sitting: string; status: string };

export type QueueItem = {
  id: string;
  kind: ExceptionKind;
  state: "open" | "resolved";
  createdAt: string;
  details: Record<string, unknown>;
  exam: { id: string; title: string; paper: string; code: string | null } | null;
  booking: QueueBooking | null;
  /** The candidate whose copy the page was printed for (pages with a code). */
  printedFor: QueueBooking | null;
  script: { id: string; number: string; state: string; source: string; version: number; complete: boolean; late: boolean; lateDecision: string | null } | null;
  page: QueuePage | null;
  /** For a duplicate: the page kept for that copy page. */
  keptPage: QueuePage | null;
  /** For mixed versions and missing pages: the pages the script shows now. */
  linkedPages: { copyPage: number; page: QueuePage }[];
  upload: { id: string; kind: string; state: string; source: "home" | "centre"; position: number | null; batchNumber: string | null; submissionSeq: number | null } | null;
  /** For a late hand-in: the submission handed in late. */
  submission: { id: string; seq: number; state: string; submittedAt: string | null } | null;
  resolved: { by: string | null; at: string | null; resolution: string | null; reason: string | null } | null;
};

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const numbers = (v: unknown): number[] => (Array.isArray(v) ? v.filter((x): x is number => typeof x === "number" && Number.isFinite(x)) : []);
const isKind = (v: unknown): v is ExceptionKind => typeof v === "string" && (EXCEPTION_KINDS as readonly string[]).includes(v);

function parseArea(v: unknown): QueueArea | null {
  if (!isObject(v)) return null;
  const x = num(v.x), y = num(v.y), w = num(v.w), h = num(v.h);
  return x === null || y === null || w === null || h === null ? null : { x, y, w, h };
}

function parsePage(v: unknown): QueuePage | null {
  if (!isObject(v)) return null;
  const id = str(v.id);
  const fullPath = str(v.full_path);
  if (!id || !fullPath) return null;
  const quality = isObject(v.quality) ? v.quality : {};
  return {
    id,
    uploadId: str(v.upload_id),
    sourceIndex: num(v.source_index),
    copyPage: num(v.copy_page),
    state: str(v.state) ?? "",
    blank: v.blank === true,
    flags: Array.isArray(quality.flags) ? quality.flags.filter((f): f is string => typeof f === "string") : [],
    rotation: num(v.rotation) ?? 0,
    fullPath,
    markingPath: str(v.marking_path),
    placedAfter: num(v.placed_after),
    replaced: v.replaced === true,
    paperVersion: num(v.paper_version),
    paperCurrent: typeof v.paper_current === "boolean" ? v.paper_current : null,
    areas: Array.isArray(v.areas) ? v.areas.map(parseArea).filter((a): a is QueueArea => a !== null) : [],
  };
}

function parseBooking(v: unknown): QueueBooking | null {
  if (!isObject(v)) return null;
  const id = str(v.id);
  if (!id) return null;
  return { id, name: str(v.name), indexNumber: str(v.index_number), sitting: str(v.sitting) ?? "", status: str(v.status) ?? "" };
}

function parseItem(v: unknown): QueueItem | null {
  if (!isObject(v)) return null;
  const id = str(v.id);
  const createdAt = str(v.created_at);
  if (!id || !createdAt || !isKind(v.kind) || (v.state !== "open" && v.state !== "resolved")) return null;
  const exam = isObject(v.exam) && str(v.exam.id) ? { id: str(v.exam.id)!, title: str(v.exam.title) ?? "", paper: str(v.exam.paper) ?? "", code: str(v.exam.code) } : null;
  const s = isObject(v.script) ? v.script : null;
  const u = isObject(v.upload) ? v.upload : null;
  const sub = isObject(v.submission) ? v.submission : null;
  const r = isObject(v.resolved) ? v.resolved : null;
  return {
    id,
    kind: v.kind,
    state: v.state,
    createdAt,
    details: isObject(v.details) ? v.details : {},
    exam,
    booking: parseBooking(v.booking),
    printedFor: parseBooking(v.printed_for),
    script:
      s && str(s.id) && str(s.number)
        ? {
            id: str(s.id)!,
            number: str(s.number)!,
            state: str(s.state) ?? "",
            source: str(s.source) ?? "",
            version: num(s.version) ?? 0,
            complete: s.complete === true,
            late: s.late === true,
            lateDecision: str(s.late_decision),
          }
        : null,
    page: parsePage(v.page),
    keptPage: parsePage(v.kept_page),
    linkedPages: Array.isArray(v.linked_pages)
      ? v.linked_pages.flatMap((l) => {
          const p = isObject(l) ? parsePage(l.page) : null;
          const n = isObject(l) ? num(l.copy_page) : null;
          return p && n !== null ? [{ copyPage: n, page: p }] : [];
        })
      : [],
    upload:
      u && str(u.id)
        ? {
            id: str(u.id)!,
            kind: str(u.kind) ?? "",
            state: str(u.state) ?? "",
            source: u.source === "home" ? "home" : "centre",
            position: num(u.position),
            batchNumber: str(u.batch_number),
            submissionSeq: num(u.submission_seq),
          }
        : null,
    submission: sub && str(sub.id) ? { id: str(sub.id)!, seq: num(sub.seq) ?? 0, state: str(sub.state) ?? "", submittedAt: str(sub.submitted_at) } : null,
    resolved: r ? { by: str(r.by), at: str(r.at), resolution: str(r.resolution), reason: str(r.reason) } : null,
  };
}

/** script_exceptions_list's answer, or null for a failure or an answer that is not one. Malformed items are left out. */
export function parseQueue(data: unknown): { items: QueueItem[]; more: boolean } | null {
  if (!isObject(data) || data.ok !== true || !Array.isArray(data.items)) return null;
  return { items: data.items.map(parseItem).filter((i): i is QueueItem => i !== null), more: data.more === true };
}

/** "3", "3 and 4", "2, 3 and 4". */
export function pageList(pages: readonly (number | string)[]): string {
  if (pages.length <= 1) return pages.join("");
  return `${pages.slice(0, -1).join(", ")} and ${pages[pages.length - 1]}`;
}

const FLAG_WORDS: Record<string, string> = {
  blurred: "blurred",
  dark: "too dark",
  cut_off: "cut off at an edge",
};

const NOT_EXPECTED: Record<string, string> = {
  other_booking: "This page was printed for another candidate's copy, but it was handed in with this family's answers.",
  booking_status: "This page belongs to a candidate whose booking is not paid, or was cancelled.",
  home_sitting: "This page belongs to a candidate who sits this exam at home.",
  other_centre: "This page belongs to a candidate booked at another centre.",
  absent: "This page belongs to a candidate marked absent on the register.",
};

/** What the server found, in plain words: one sentence per line. */
export function foundInWords(item: QueueItem): string[] {
  const d = item.details;
  const copyPage = num(d.copy_page) ?? item.page?.copyPage ?? null;
  const pageWord = copyPage !== null ? `Page ${copyPage}` : "This page";
  switch (item.kind) {
    case "no_code":
      return ["No code could be read on this page."];
    case "unknown_code": {
      const code = str(d.code);
      return [
        `The code on this page${code ? ` (${code}${copyPage !== null ? `, page ${copyPage}` : ""})` : ""} is not a copy of this exam's paper, or that copy has no such page.`,
      ];
    }
    case "other_exam":
      return [`This page was printed for another exam${copyPage !== null ? ` (page ${copyPage} of its copy)` : ""}. It cannot go into a script of this exam.`];
    case "not_expected":
      return [NOT_EXPECTED[str(d.reason) ?? ""] ?? "This page belongs to a candidate who was not expected in this file."];
    case "duplicate": {
      const out = [`${pageWord} was scanned more than once. The clearer page was kept and this one set aside.`];
      const a = item.page?.paperVersion ?? null;
      const b = item.keptPage?.paperVersion ?? null;
      if (a !== null && b !== null && a !== b) out.push(`This page is from version ${a} of the paper; the page kept is from version ${b}.`);
      return out;
    }
    case "missing_pages": {
      if (str(d.reason) === "no_paper") {
        return ["The answer pages of this candidate's paper are not known. Set the page roles of the exam's paper first."];
      }
      const pages = numbers(d.pages);
      const dismissed = numbers(d.dismissed);
      const out = pages.length
        ? [`Answer ${pages.length === 1 ? "page" : "pages"} ${pageList(pages)} ${pages.length === 1 ? "has" : "have"} not arrived.`]
        : ["No answer pages are missing any more."];
      if (dismissed.length) out.push(`${dismissed.length === 1 ? "Page" : "Pages"} ${pageList(dismissed)} ${dismissed.length === 1 ? "was" : "were"} confirmed as left blank.`);
      return out;
    }
    case "uncoded_family_page": {
      const after = num(d.after_page);
      return [`The family added a page with no code${after !== null ? ` and said it follows page ${after}` : ""}.`];
    }
    case "mixed_versions": {
      const parts = item.linkedPages
        .filter((l) => l.page.paperVersion !== null)
        .map((l) => `page ${l.copyPage} is version ${l.page.paperVersion}`);
      return [`This script shows pages printed from two versions of the paper${parts.length ? `: ${parts.join("; ")}` : ""}.`];
    }
    case "poor_quality": {
      const flags = Array.isArray(d.flags) ? d.flags.filter((f): f is string => typeof f === "string") : (item.page?.flags ?? []);
      const words = flags.map((f) => FLAG_WORDS[f]).filter((w): w is string => !!w);
      const out: string[] = [];
      if (words.length) out.push(`${pageWord} is ${pageList(words)}.`);
      if (flags.includes("layout_unexpected")) {
        out.push("The page was not where it should be on the picture, so the name band could not be hidden and no marking picture was made.");
        out.push("Hide the candidate's name on the full page, then accept it.");
      } else if (d.marking_picture === false) {
        out.push("No marking picture could be made for this answer page.");
      }
      if (str(d.from) === "family") out.push("The family sent it as it is instead of taking it again.");
      return out.length ? out : [`${pageWord} may be hard to mark.`];
    }
    case "late": {
      const seq = item.submission?.seq ?? num(d.seq);
      const at = item.submission?.submittedAt;
      return [`Handed in late (submission ${seq ?? "?"}${at ? `, ${formatLondon(at)}` : ""}). Decide whether the script is marked.`];
    }
    case "name_visible":
      return ["A marker reported that a name can be seen on this page. Hide it, then confirm."];
    case "processing_failed": {
      const attempts = num(d.attempts);
      return [`The file could not be prepared${attempts !== null ? ` after ${attempts} attempts` : ""}.`];
    }
  }
}

export type QueueAction =
  | "assign"
  | "blank"
  | "keep_existing"
  | "reject"
  | "confirm"
  | "dismiss_missing"
  | "late_accept"
  | "late_reject"
  | "hide_areas";

const ACTIONS: Record<ExceptionKind, QueueAction[]> = {
  no_code: ["assign", "blank", "reject"],
  unknown_code: ["assign", "blank", "reject"],
  not_expected: ["assign", "blank", "reject"],
  other_exam: ["blank", "reject"],
  duplicate: ["keep_existing", "assign"],
  missing_pages: ["dismiss_missing"],
  uncoded_family_page: ["confirm", "assign", "blank", "reject"],
  mixed_versions: ["confirm"],
  poor_quality: ["hide_areas", "confirm", "reject"],
  name_visible: ["hide_areas", "confirm"],
  late: ["late_accept", "late_reject"],
  processing_failed: ["confirm", "reject"],
};

/** The actions that fit an open exception (none once resolved). */
export function actionsFor(item: QueueItem): QueueAction[] {
  if (item.state !== "open") return [];
  if (item.kind === "missing_pages" && numbers(item.details.pages).length === 0) return [];
  if (item.kind === "late" && !item.script) return [];
  return ACTIONS[item.kind];
}

/** Whether rejecting this exception rejects a family's submission. */
export const rejectsSubmission = (item: QueueItem) => item.upload?.source === "home";

export function actionLabel(action: QueueAction, item: QueueItem): string {
  switch (action) {
    case "assign":
      return item.kind === "duplicate" ? "Use this page instead" : "Assign to a candidate";
    case "blank":
      return "Mark as blank";
    case "keep_existing":
      return "Keep the page already chosen";
    case "reject":
      return rejectsSubmission(item) ? "Reject the submission" : "Reject this page";
    case "confirm":
      return item.kind === "poor_quality"
        ? "Accept as it is"
        : item.kind === "uncoded_family_page"
          ? "Confirm the family's placement"
          : item.kind === "mixed_versions"
            ? "Check again"
            : item.kind === "name_visible"
              ? "Name is hidden"
              : "Noted";
    case "dismiss_missing":
      return "Confirm left blank";
    case "late_accept":
      return "Mark the late script";
    case "late_reject":
      return "Do not mark it";
    case "hide_areas":
      return "Hide the name";
  }
}

/** Whether the action asks for a reason (confirming does not). */
export const reasonRequired = (action: QueueAction) => action !== "confirm";

export const REASON_MESSAGE = "Give a reason of 3 to 300 characters.";

/** The reason's problem, or null when it will do: 3 to 300 characters once trimmed (or empty, when optional). */
export function reasonProblem(reason: string, required: boolean): string | null {
  const n = reason.trim().length;
  if (n === 0) return required ? REASON_MESSAGE : null;
  return n < 3 || n > 300 ? REASON_MESSAGE : null;
}

export type ResolveInput =
  | { action: "assign"; exceptionId: string; bookingId: string; copyPage: number; reason: string }
  | { action: "blank" | "keep_existing" | "reject"; exceptionId: string; reason: string }
  | { action: "confirm"; exceptionId: string; reason?: string }
  | { action: "dismiss_missing"; exceptionId: string; pages: number[]; reason: string }
  | { action: "late_accept" | "late_reject"; scriptId: string; reason: string };

/** The database function an action calls, with its arguments. */
export function rpcFor(input: ResolveInput): { fn: string; args: Record<string, unknown> } {
  switch (input.action) {
    case "assign":
      return {
        fn: "script_exception_assign",
        args: { p_exception: input.exceptionId, p_booking: input.bookingId, p_copy_page: input.copyPage, p_reason: input.reason.trim() },
      };
    case "blank":
    case "keep_existing":
    case "reject":
      return { fn: `script_exception_${input.action}`, args: { p_exception: input.exceptionId, p_reason: input.reason.trim() } };
    case "confirm": {
      const reason = (input.reason ?? "").trim();
      return { fn: "script_exception_confirm", args: reason ? { p_exception: input.exceptionId, p_reason: reason } : { p_exception: input.exceptionId } };
    }
    case "dismiss_missing":
      return { fn: "script_exception_dismiss_missing", args: { p_exception: input.exceptionId, p_pages: input.pages, p_reason: input.reason.trim() } };
    case "late_accept":
    case "late_reject":
      return { fn: "script_late_decide", args: { p_script: input.scriptId, p_accept: input.action === "late_accept", p_reason: input.reason.trim() } };
  }
}

const RESOLUTIONS: Record<string, string> = {
  assigned: "Assigned to a candidate",
  blank: "Marked blank",
  kept: "Kept the page already chosen",
  rejected: "Rejected",
  confirmed: "Confirmed",
  dismissed: "Confirmed left blank",
  late_accepted: "Late script accepted",
  late_rejected: "Late script not marked",
  one_version: "Pages made one version",
  set_aside: "Set aside with its page",
  submission_rejected: "Submission rejected",
  pages_arrived: "Pages arrived",
  not_expected: "Candidate no longer expected",
};

export const resolutionLabel = (r: string | null) => (r ? (RESOLUTIONS[r] ?? r) : "");

/** A second resolution's answer: who resolved it first, and when. */
export function conflictMessage(r: { resolved_by?: unknown; resolved_at?: unknown }): string {
  const by = str(r.resolved_by);
  const at = str(r.resolved_at);
  if (!by && !at) return "This has already been resolved. Refresh the page to see how.";
  return `Already resolved${by ? ` by ${by}` : ""}${at ? ` on ${formatLondon(at)}` : ""}. Refresh the page.`;
}

/** The candidate, as the queue names them. */
export function candidateLabel(b: QueueBooking | null): string {
  if (!b) return "Candidate not known";
  const name = b.name ?? "Removed account";
  return b.indexNumber ? `${name} (${b.indexNumber})` : name;
}

/** Copy pages 1 to n, for the page picker. */
export const copyPages = (n: number | null) => Array.from({ length: Math.max(0, Math.min(n ?? 0, 200)) }, (_, i) => i + 1);
