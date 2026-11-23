// Answers a family uploaded but never submitted (public.home_drafts_unsubmitted), and what staff can do about them
// (public.home_submission_accept_draft). Pure: the page reads the list on the server.

/** A draft that holds stored files, of an active home booking, once its exam has finished. */
export type UnsentDraft = {
  submissionId: string;
  bookingId: string | null;
  name: string | null;
  indexNumber: string | null;
  exam: { id: string; title: string; paper: string | null; startsAt: string } | null;
  files: number;
  lastFileAt: string | null;
  /** Whether accepting it now marks it late (the on-time deadline, finish + 2 hours, has passed). */
  late: boolean;
  /** The booking already has a submission that was handed in (not a draft, not rejected). */
  replacesReceived: boolean;
  /** Submitting this draft replaces every page already received, not just some. */
  replacesAll: boolean;
  /** The pages of the script's current version. */
  receivedPages: number;
};

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const text = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

function draft(x: unknown): UnsentDraft | null {
  if (!isRecord(x)) return null;
  const submissionId = text(x.submission_id);
  if (!submissionId) return null;
  const b = isRecord(x.booking) ? x.booking : null;
  const e = isRecord(x.exam) ? x.exam : null;
  const examId = e ? text(e.id) : null;
  const title = e ? text(e.title) : null;
  const startsAt = e ? text(e.starts_at) : null;
  return {
    submissionId,
    bookingId: b ? text(b.id) : null,
    name: b ? text(b.name) : null,
    indexNumber: b ? text(b.index_number) : null,
    exam: e && examId && title && startsAt ? { id: examId, title, paper: text(e.paper), startsAt } : null,
    files: typeof x.files === "number" && Number.isInteger(x.files) && x.files >= 0 ? x.files : 0,
    lastFileAt: text(x.last_file_at),
    late: x.late === true,
    replacesReceived: x.replaces_received === true,
    replacesAll: x.replaces_all !== false,
    receivedPages: typeof x.received_pages === "number" && Number.isInteger(x.received_pages) && x.received_pages >= 0 ? x.received_pages : 0,
  };
}

/** home_drafts_unsubmitted's answer, or null for a refusal or a broken answer. Malformed rows are left out. */
export function parseUnsentDrafts(data: unknown): UnsentDraft[] | null {
  if (!isRecord(data) || data.ok !== true || !Array.isArray(data.items)) return null;
  return data.items.map(draft).filter((d): d is UnsentDraft => d !== null);
}

/** What submitting the draft does to pages the family already handed in, or null when it replaces none. */
export function replacesNote(d: Pick<UnsentDraft, "replacesReceived" | "replacesAll" | "receivedPages">): string | null {
  if (!d.replacesReceived) return null;
  return d.replacesAll
    ? `Submitting this replaces all ${d.receivedPages} pages already received.`
    : "Submitting this replaces some of the pages already received.";
}

/** "Sam One (SE-2098-7701)", or what is known of the candidate. */
export function draftCandidate(d: UnsentDraft): string {
  if (d.name && d.indexNumber) return `${d.name} (${d.indexNumber})`;
  return d.name ?? d.indexNumber ?? "A candidate";
}

export const UNSENT_TEXT = {
  title: "Answers uploaded but not sent",
  intro:
    "These families uploaded pages but did not press Submit, so nothing was handed in. The files are kept. " +
    "You can submit them for the family: they are then checked like any other hand-in.",
  none: "No family has left uploaded pages unsent.",
  accept: "Submit for the family",
  late: "Will be marked late",
  onTime: "On time",
  reason: "Reason (kept in the audit log)",
} as const;

export const ACCEPT_REASON_MESSAGE = "Give a reason of 3 to 300 characters.";

/** The reason's problem, or null when it will do (3 to 300 characters once trimmed). */
export function acceptReasonProblem(reason: string): string | null {
  const n = reason.trim().length;
  return n < 3 || n > 300 ? ACCEPT_REASON_MESSAGE : null;
}

const ACCEPT_FAILURES: Record<string, string> = {
  forbidden: "You do not have permission to do that.",
  reason_required: ACCEPT_REASON_MESSAGE,
  not_found: "These answers could not be found. Refresh the page.",
  conflict: "These answers have already been submitted. Refresh the page.",
  nothing_to_submit: "There is no uploaded file to submit any more. Refresh the page.",
  booking_not_active: "This booking is no longer an active home booking, so its answers cannot be submitted.",
  script_locked: "This candidate's answers are already being marked.",
};

/** What home_submission_accept_draft's answer says to staff. */
export function acceptDraftMessage(a: { ok?: unknown; code?: unknown; late?: unknown; files?: unknown }): { ok: boolean; message: string } {
  if (a.ok === true) {
    const files = typeof a.files === "number" ? a.files : 0;
    const what = `${files} ${files === 1 ? "file was" : "files were"} submitted for the family and ${files === 1 ? "is" : "are"} being checked.`;
    return { ok: true, message: a.late === true ? `${what} The hand-in is marked late: decide in the exception queue whether it is marked.` : what };
  }
  const code = typeof a.code === "string" ? a.code : "";
  return { ok: false, message: ACCEPT_FAILURES[code] ?? "Something went wrong. Please try again." };
}

const SKIP_FAILURES: Record<string, string> = {
  forbidden: "You do not have permission to do that.",
  reason_required: ACCEPT_REASON_MESSAGE,
};

export const SKIP_TEXT = {
  button: "Do not send them",
  reason: "Reason (kept in the audit log)",
} as const;

/** The line on the admin home page about family emails that are still to be sent. */
export function familyNoticesLine(count: number): string {
  return `${count} family ${count === 1 ? "email is" : "emails are"} waiting to be sent.`;
}

/** What script_family_notices_skip's answer says to staff. */
export function skipNoticesMessage(a: { ok?: unknown; code?: unknown; skipped?: unknown }): { ok: boolean; message: string } {
  if (a.ok === true) {
    const n = typeof a.skipped === "number" ? a.skipped : 0;
    return { ok: true, message: `${n} family ${n === 1 ? "email was" : "emails were"} not sent.` };
  }
  const code = typeof a.code === "string" ? a.code : "";
  return { ok: false, message: SKIP_FAILURES[code] ?? "Something went wrong. Please try again." };
}
