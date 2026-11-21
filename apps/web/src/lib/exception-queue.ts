/** The exception queue: what script_exceptions_list answers, the plain words staff read for each problem, which
 * actions fit it, and the calls those actions make. The database checks every rule again. */
import { exceptionMessageFor } from "@stem/shared";
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
  /** Whether rejecting it rejects a family's submission (the database works it out: script_reject_targets). */
  rejectsSubmission: boolean;
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
    rejectsSubmission: v.rejects_submission === true,
    resolved: r ? { by: str(r.by), at: str(r.at), resolution: str(r.resolution), reason: str(r.reason) } : null,
  };
}

/** One exception as the queue (and the script repository's detail) answers it, or null when it is not one. */
export const parseQueueItem = (v: unknown): QueueItem | null => parseItem(v);

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
  script_locked: "This page belongs to a candidate whose script is already being marked, so it was not added to the script: tell the marking lead.",
};

/** What the server found, in plain words: one sentence per line. */
export function foundInWords(item: QueueItem): string[] {
  const words = foundWords(item);
  if (isBeingMarked(item) && !isStaleNotice(item) && item.page) {
    words.push("The script is being marked, so this page's hidden areas can no longer change here: tell the marking lead.");
  } else if (isLocked(item) && !isStaleNotice(item) && item.page) {
    words.push(`The script is ${item.script?.state === "void" ? "void" : "withdrawn"}, so this page's hidden areas can no longer change.`);
  }
  if (item.page?.replaced && item.state === "open") {
    words.push("The file was processed again and this page was replaced: its name can no longer be hidden here, and it cannot be assigned.");
  }
  return words;
}

function foundWords(item: QueueItem): string[] {
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
      if (str(d.reason) === "in_other_script") {
        return [
          `${pageWord} is already in another candidate's script, so it was left out of this one.`,
          "A page can be in one script only: keep it where it is, or take it out of the other script first and then use it here.",
        ];
      }
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
      // A page with a code carries the printed name box: only a staff area will do (Ruling R40).
      const hideWords = item.page && !isCodeless(item.page)
        ? "Hide the candidate's name on the full page (draw a box over the printed name box), then accept it."
        : "Hide the candidate's name on the full page, or tick that there is none, then accept it.";
      if (words.length) out.push(`${pageWord} is ${pageList(words)}.`);
      if (flags.includes("layout_unexpected")) {
        out.push("The page was not where it should be on the picture, so the name band could not be hidden and no marking picture was made.");
        out.push("Hide the candidate's name on the full page, then accept it.");
      } else if (str(d.from) === "remask" && d.stale_marking === true) {
        out.push("Its marking pictures could not be made again after its hidden areas changed, and the script is already being marked: the marking picture it has may be out of date.");
        out.push("Its hidden areas can no longer change here: tell the marking lead, then note it.");
      } else if (str(d.from) === "remask" && d.reprocessed === true) {
        out.push("Check the name again after reprocessing: the file was read again from the original, and staff work on this page (hidden areas, confirmation, placement) has to be done again.");
        out.push(hideWords);
      } else if (str(d.from) === "remask") {
        out.push("Its marking picture could not be made again after its hidden areas or its turn changed, so the old one was taken away (this is not the family's file).");
        out.push(hideWords);
        out.push("A page with a code gets its marking picture back only from its print layout: turn it back upright, or process its file again from the script's page.");
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
      if (isRemaskFailure(item)) {
        return [
          "The marking pictures could not be made (this is not the family's file), so the file's old ones were taken away.",
          "Noting it has them made again.",
        ];
      }
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
  no_code: ["hide_areas", "assign", "blank", "reject"],
  unknown_code: ["hide_areas", "assign", "blank", "reject"],
  not_expected: ["assign", "blank", "reject"],
  other_exam: ["blank", "reject"],
  duplicate: ["keep_existing", "assign"],
  missing_pages: ["dismiss_missing"],
  uncoded_family_page: ["hide_areas", "confirm", "assign", "blank", "reject"],
  mixed_versions: ["confirm"],
  poor_quality: ["hide_areas", "confirm", "reject"],
  name_visible: ["hide_areas", "confirm"],
  late: ["late_accept", "late_reject"],
  processing_failed: ["confirm", "reject"],
};

/** A remask job (re-making marking pictures) that failed for good: not the family's file. */
export const isRemaskFailure = (item: QueueItem) => item.kind === "processing_failed" && item.details.kind === "remask";

/** A page whose marking picture a remask could not make again: not the family's file (Ruling R31). */
export const isRemaskQuality = (item: QueueItem) => item.kind === "poor_quality" && item.details.from === "remask";

/** The actions that fit an open exception (none once resolved). A remask failure can only be noted; a page whose
 * marking picture a remask could not make again is never rejected (the family's file was fine). */
export function actionsFor(item: QueueItem): QueueAction[] {
  if (item.state !== "open") return [];
  if (item.kind === "missing_pages" && numbers(item.details.pages).length === 0) return [];
  if (item.kind === "late" && !item.script) return [];
  if (isRemaskFailure(item) || isStaleNotice(item)) return ["confirm"];
  const actions = isRemaskQuality(item) ? (["hide_areas", "confirm"] as QueueAction[]) : ACTIONS[item.kind];
  // Only what the database allows is offered. It refuses hidden areas on a page of a script past verification
  // (R34 d), and hidden areas and assigning for a page a rerun replaced (page_replaced, R35).
  const refused: QueueAction[] = [];
  if (isLocked(item)) refused.push("hide_areas");
  if (item.page?.replaced) refused.push("hide_areas", "assign");
  return actions.filter((a) => !refused.includes(a));
}

/** A script past verification (being marked, marked, withdrawn or void): its pages no longer change here. */
export const isLocked = (item: QueueItem) =>
  item.script !== null && !["receiving", "checking", "needs_attention", "verified"].includes(item.script.state);

/** A script that is really being marked (ready to mark up to final), not one withdrawn or void (R35). */
export const isBeingMarked = (item: QueueItem) =>
  item.script !== null && ["ready_to_mark", "marking", "marked", "checked", "final"].includes(item.script.state);

/** A script being marked kept a marking picture a failed remask could not make again (stale_marking): only noted. */
export const isStaleNotice = (item: QueueItem) => item.kind === "poor_quality" && item.details.stale_marking === true;

/** Whether rejecting this exception rejects a family's submission (as the database says). */
export const rejectsSubmission = (item: QueueItem) => item.rejectsSubmission;

/** A page with no known copy (no code read, or an unknown one): its layout can never place the name band. */
export const isCodeless = (p: QueuePage) => p.paperVersion === null;

/** Whether confirming (or assigning) needs a staff hidden area on the page first, or "There is no name on this page",
 * while none is drawn: confirming a page whose layout was unexpected, a reported visible name, a page whose marking
 * picture a remask could not make again, or a page with no code (a family's placement, a poor-quality page); and
 * assigning a page with no code (Ruling R31). The database checks the same. */
export function needsNameCheck(item: QueueItem, action: "confirm" | "assign" | QueueAction = "confirm"): boolean {
  const p = item.page;
  if (!p || p.areas.length > 0) return false;
  if (action === "assign") return isCodeless(p);
  if (action !== "confirm") return false;
  if (item.kind === "name_visible" || item.kind === "uncoded_family_page") return true;
  if (isStaleNotice(item)) return false;
  return item.kind === "poor_quality" && (p.flags.includes("layout_unexpected") || isRemaskQuality(item) || isCodeless(p));
}

/** Said instead of the "no name" tick for a page with a code (Ruling R40): its printed name box must be covered. */
export const NAME_BOX_MESSAGE = "This page has a printed name box. Draw a box over the name before confirming.";

/** Whether "There is no name on this page" is offered where the name check applies: only for a page with no code.
 * A page with a code always carries the printed name box, and when its layout was not proved (a "Fit to page" print)
 * nothing but a staff hidden area covers it, so the database refuses "no name" for it (name_area_required). */
export function noNameOffered(item: QueueItem, action: "confirm" | "assign" | QueueAction = "confirm"): boolean {
  return needsNameCheck(item, action) && item.page !== null && isCodeless(item.page);
}

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
      return isStaleNotice(item)
        ? "Noted"
        : item.kind === "poor_quality"
        ? "Accept as it is"
        : item.kind === "uncoded_family_page"
          ? "Confirm the family's placement"
          : item.kind === "mixed_versions"
            ? "Check again"
            : item.kind === "name_visible"
              ? "Name is hidden"
              : isRemaskFailure(item)
                ? "Make the marking pictures again"
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
  | { action: "assign"; exceptionId: string; bookingId: string; copyPage: number; reason: string; replace?: boolean; noName?: boolean }
  | { action: "blank" | "keep_existing" | "reject"; exceptionId: string; reason: string }
  | { action: "confirm"; exceptionId: string; reason?: string; noName?: boolean }
  | { action: "dismiss_missing"; exceptionId: string; pages: number[]; reason: string }
  | { action: "late_accept" | "late_reject"; scriptId: string; reason: string };

/** The database function an action calls, with its arguments. */
export function rpcFor(input: ResolveInput): { fn: string; args: Record<string, unknown> } {
  switch (input.action) {
    case "assign":
      return {
        fn: "script_exception_assign",
        args: {
          p_exception: input.exceptionId,
          p_booking: input.bookingId,
          p_copy_page: input.copyPage,
          p_reason: input.reason.trim(),
          ...(input.replace ? { p_replace: true } : {}),
          ...(input.noName ? { p_no_name: true } : {}),
        },
      };
    case "blank":
    case "keep_existing":
    case "reject":
      return { fn: `script_exception_${input.action}`, args: { p_exception: input.exceptionId, p_reason: input.reason.trim() } };
    case "confirm": {
      const reason = (input.reason ?? "").trim();
      return {
        fn: "script_exception_confirm",
        args: { p_exception: input.exceptionId, ...(reason ? { p_reason: reason } : {}), ...(input.noName ? { p_no_name: true } : {}) },
      };
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
  marking_made: "Marking picture made",
  submission_rejected: "Submission rejected",
  pages_arrived: "Pages arrived",
  not_expected: "Candidate no longer expected",
};

export const resolutionLabel = (r: string | null) => (r ? (RESOLUTIONS[r] ?? r) : "");

/** A conflict answer: a copy page already holding a page (occupied), a page that changed meanwhile, or a second
 * resolution (who resolved it first, and when). */
export function conflictMessage(r: { resolved_by?: unknown; resolved_at?: unknown; reason?: unknown }): string {
  if (r.reason === "occupied") return "That page of the candidate's script already holds a page. Tick \"Replace the page that is there\" to replace it.";
  if (r.reason === "changed") return "This page changed while you were working. Refresh the page and try again.";
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

/** What a resolution answered (the fields the messages need). */
export type ResolveAnswer = { outcome?: unknown; replaced_page_id?: unknown; state?: unknown };

/** What the screen says after a resolution, from what the database says happened. */
export function resolvedMessage(input: ResolveInput, a: ResolveAnswer): string {
  switch (input.action) {
    case "assign":
      return a.replaced_page_id
        ? "Assigned. The page is in the candidate's script; the page that was there is kept for review as a duplicate."
        : "Assigned. The page is in the candidate's script.";
    case "blank":
      return "Marked as blank. The page is set aside.";
    case "keep_existing":
      return "Kept the page already chosen.";
    case "reject":
      return a.outcome === "submission_rejected"
        ? "Rejected. The family's submission is rejected and they have been emailed with your reason."
        : a.outcome === "set_aside"
          ? "Rejected. The page is set aside."
          : "Rejected. A later upload had already replaced this page, so nothing else changed.";
    case "confirm":
      return "Confirmed.";
    case "dismiss_missing":
      return a.state === "resolved" ? "Confirmed as left blank." : "Saved. Some pages are still missing.";
    case "late_accept":
      return "The late script will be marked.";
    case "late_reject":
      return a.outcome === "void"
        ? "The script is void, so it will not be marked. The family has been emailed with your reason."
        : "The late upload is set aside; the on-time pages are used. The family has been emailed with your reason.";
  }
}

/** What the screen says when a resolution was refused. */
export function failureMessage(a: { code?: unknown; reason?: unknown; resolved_by?: unknown; resolved_at?: unknown }): string {
  if (a.code === "conflict") return conflictMessage(a);
  if (a.code === "forbidden" && a.reason === "other_family") return exceptionMessageFor("other_family");
  return exceptionMessageFor(typeof a.code === "string" ? a.code : null);
}

/** A candidate of the exam that "Assign" can choose. */
export type CandidateOption = {
  bookingId: string;
  name: string;
  indexNumber: string | null;
  sitting: string;
  status: string;
  /** Present, late or absent on the register, or null. */
  attendance: string | null;
  scriptNumber: string | null;
  /** The copy pages their script shows now. */
  pages: number[];
  /** How many pages their copy has (the pages a page can be assigned to). */
  copyPages: number | null;
};

/** script_exception_candidates' answer, or null for a failure. Malformed rows are left out. */
export function parseCandidates(data: unknown): CandidateOption[] | null {
  if (!isObject(data) || data.ok !== true || !Array.isArray(data.candidates)) return null;
  return data.candidates.flatMap((c): CandidateOption[] => {
    if (!isObject(c) || !str(c.booking_id)) return [];
    return [
      {
        bookingId: str(c.booking_id)!,
        name: str(c.name) ?? "No name",
        indexNumber: str(c.index_number),
        sitting: str(c.sitting) ?? "",
        status: str(c.status) ?? "",
        attendance: str(c.attendance),
        scriptNumber: str(c.script_number),
        pages: numbers(c.pages),
        copyPages: num(c.copy_pages),
      },
    ];
  });
}
