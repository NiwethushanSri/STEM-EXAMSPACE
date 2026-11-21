/** What `home_submission_status` tells a family about the answers they hand in, and the words they see for it. */

export type UploadKind = "home_photo" | "home_pdf";

export type DraftUpload = {
  id: string;
  kind: UploadKind;
  mime: string;
  byte_size: number;
  state: string;
  position: number | null;
  storage_path: string;
  /** Uploaded by the signed-in person (only they can finish it or see the file). */
  mine: boolean;
};

export type HomeUploadStatus = {
  /** The latest submission handed in (not a draft). */
  submission: {
    id: string;
    seq: number;
    state: string;
    late: boolean;
    submitted_at: string | null;
    checked_at: string | null;
    replaces_all: boolean;
    /** Why staff rejected it (shown with "Rejected"); only for a rejected submission. */
    rejected_reason?: string | null;
  } | null;
  pages: { page_id: string; copy_page: number | null; state: string; flags: string[]; upload_id: string; source_index: number; file_number: number }[];
  missing: number[];
  retake: { page_id: string; copy_page: number; flags: string[] }[];
  unplaced: { page_id: string; upload_id: string; source_index: number; file_number: number }[];
  failed: number[];
  blank: number[];
  script: { number: string; state: string; pages: number[] } | null;
  copy_pages: number | null;
  draft: { id: string; seq: number; replaces_all: boolean; uploads: DraftUpload[] } | null;
};

export const MAX_FILES = 60;
export const MAX_PHOTO_BYTES = 25 * 1024 * 1024;
export const MAX_PDF_BYTES = 100 * 1024 * 1024;
/** How often the screen asks the server again while the pages are being checked. */
export const POLL_MS = 3000;

export const UPLOAD_TEXT = {
  uploading: "Uploading",
  checking: "Checking your pages",
  received: "Received",
  attention: "Needs your attention",
  late: "Submitted late",
  rejected: "Rejected",
  receiptHeading: "We have received your answers",
  photoAdvice: "Photograph each page on its own, flat, from directly above, on a plain dark surface.",
  dropZone: "Upload a PDF or photos",
  dropHint: "Drop a PDF from your scanner, or several photos, here, or choose them.",
  chooseFiles: "Choose files",
  photograph: "Photograph pages",
  blurred: "This photo is blurred. Retake it?",
  retake: "Retake",
  keep: "Keep it",
  remove: "Delete",
  tryAgain: "Try again",
  uploaded: "Uploaded",
  notFinished: "This file did not finish uploading. Delete it and add it again.",
  elsewhere: "Still uploading on another device.",
  submit: "Submit",
  notSent: "Your pages are not sent yet. Press Submit to send them.",
  notSentUploading: "Your pages are not sent yet. Wait until every file shows as uploaded, then press Submit.",
  submitHint: "Submit when every page is uploaded. You can still replace pages until the deadline.",
  checkingHint: "The pages are being read. This usually takes a minute or two; you can leave this page.",
  replaceAll: "Replace all pages",
  replaceSome: "Replace some pages",
  replaceSomeHint: "Add only the pages you want to replace or add. The other pages you handed in stay as they are.",
  continueDraft: "Continue your new upload",
  back: "Back",
  sendAsIs: "Send as it is",
  yes: "Yes",
  addPage: "Add the page",
  whichPage: "Which page does this follow?",
  save: "Save",
  attentionNone: "The institution is checking your pages and will be in touch if anything is needed.",
  lateNote: "These answers were handed in after the on-time deadline. The institution decides whether they are marked.",
  rejectedNote: "Your answers were not accepted. Please upload them again.",
  rejectedReason: "Reason from the institution:",
  closed: "Uploads for this exam have closed. If you could not hand in your answers, please contact the institution.",
  print: "Print",
  loadFailure: "Your upload could not be loaded. Please try again.",
} as const;

export const retakePrompt = (n: number) => `Retake page ${n}`;
export const blankPrompt = (n: number) => `Was page ${n} left blank?`;

/**
 * The status word for the latest submission. Only the server's state can make it "Received" (or "Submitted late",
 * a received submission handed in late): nothing the screen does on its own says so.
 */
export function statusWord(submission: HomeUploadStatus["submission"]): string | null {
  switch (submission?.state) {
    case "checking":
      return UPLOAD_TEXT.checking;
    case "needs_attention":
      return UPLOAD_TEXT.attention;
    case "received":
      return submission.late ? UPLOAD_TEXT.late : UPLOAD_TEXT.received;
    case "rejected":
      return UPLOAD_TEXT.rejected;
    default:
      return null;
  }
}

const FLAG_WORDS: Record<string, string> = {
  blurred: "It is blurred.",
  dark: "It is too dark.",
  cut_off: "Part of the page is cut off.",
  layout_unexpected: "It could not be lined up. Photograph it on its own, flat, from directly above.",
};

export type AttentionItem =
  | { kind: "retake"; pageId: string; page: number; reason: string }
  | { kind: "missing"; page: number }
  | { kind: "unplaced"; pageId: string; file: number; sourcePage: number }
  | { kind: "failed"; file: number };

/** What the family can do about answers that need attention: pages to retake (or send as they are), answer pages
 * not handed in, pages with no code to place, and files that could not be read. Empty in any other state. */
export function attentionItems(status: HomeUploadStatus): AttentionItem[] {
  if (status.submission?.state !== "needs_attention") return [];
  const retake: AttentionItem[] = status.retake.map((r) => ({
    kind: "retake",
    pageId: r.page_id,
    page: r.copy_page,
    reason: r.flags.map((f) => FLAG_WORDS[f]).filter(Boolean).join(" ") || "It could not be read clearly.",
  }));
  const missing: AttentionItem[] = status.missing.map((page) => ({ kind: "missing", page }));
  const unplaced: AttentionItem[] = status.unplaced.map((u) => ({
    kind: "unplaced",
    pageId: u.page_id,
    file: u.file_number,
    sourcePage: u.source_index + 1,
  }));
  const failed: AttentionItem[] = status.failed.map((file) => ({ kind: "failed", file }));
  return [...retake, ...missing, ...unplaced, ...failed];
}

const PHOTO_TYPES = ["image/jpeg", "image/png", "image/heic", "image/heif"];
const BY_EXTENSION: Record<string, string> = {
  pdf: "application/pdf",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  png: "image/png",
  heic: "image/heic",
  heif: "image/heif",
};

/** The upload kind and content type of a chosen file: the browser's type when it is one we take, else the file
 * name's extension (browsers often give HEIC photos no type). Null for anything else. */
export function uploadFileType(name: string, type: string): { kind: UploadKind; mime: string } | null {
  const t = type.trim().toLowerCase();
  const ext = /\.([a-z0-9]+)$/i.exec(name)?.[1]?.toLowerCase() ?? "";
  const mime = t === "application/pdf" || PHOTO_TYPES.includes(t) ? t : Object.hasOwn(BY_EXTENSION, ext) ? BY_EXTENSION[ext] : null;
  if (!mime) return null;
  return { kind: mime === "application/pdf" ? "home_pdf" : "home_photo", mime };
}

/** The server's size rule, checked before uploading: null when the size is fine. */
export function fileProblem(kind: UploadKind, bytes: number): "file_too_large" | "invalid_input" | null {
  if (!(bytes > 0)) return "invalid_input";
  return bytes > (kind === "home_pdf" ? MAX_PDF_BYTES : MAX_PHOTO_BYTES) ? "file_too_large" : null;
}

/** What home_submission_submit answers. */
export type SubmitResult = { submission_id: string; seq: number; state: string; late: boolean; submitted_at: string | null };

/**
 * The status to show once home_submission_submit has answered: the submission it names (checking, its number) in
 * place of the earlier one, nothing left of the earlier check, and no draft. The earlier "Received" and its receipt
 * cannot show while the screen waits for the server's next status.
 */
export function afterSubmit(status: HomeUploadStatus, result: SubmitResult): HomeUploadStatus {
  return {
    ...status,
    submission: {
      id: result.submission_id,
      seq: result.seq,
      state: result.state,
      late: result.late,
      submitted_at: result.submitted_at,
      checked_at: null,
      replaces_all: status.draft?.id === result.submission_id ? status.draft.replaces_all : true,
    },
    pages: [],
    missing: [],
    retake: [],
    unplaced: [],
    failed: [],
    blank: [],
    draft: null,
  };
}

/** A status older than the submission this screen handed in (a reply to a request sent before the submit). */
export function isStale(status: HomeUploadStatus, submittedSeq: number | null): boolean {
  return submittedSeq !== null && (status.submission?.seq ?? 0) < submittedSeq;
}

/** Which parts of the upload area show: the editor (first upload, or replacing, while uploads are open) or the
 * status; the receipt only for a submission the server says is received. */
export function uploadView(status: HomeUploadStatus, opts: { canUpload: boolean; editing: boolean }): { editor: boolean; receipt: boolean } {
  const editor = opts.canUpload && (opts.editing || !status.submission);
  return { editor, receipt: !editor && status.submission?.state === "received" };
}

export type StoreSteps = {
  /** Makes the upload row (script_upload_begin); throws an Error named by the failure code. */
  begin: () => Promise<{ uploadId: string; path: string }>;
  /** Sends the file to that path (resumable). */
  upload: (path: string) => Promise<void>;
  /** script_upload_stored's answer. */
  stored: (uploadId: string) => Promise<{ ok: boolean; code?: string }>;
};

/**
 * Puts one file in storage and has it accepted. A new file is begun, uploaded and stored. A file whose upload row
 * exists (a retry) is asked about first: when its upload went through but the answer to the stored call was lost,
 * that call now succeeds and nothing is sent again (storage would refuse it: no overwrite); the file is sent again
 * only when storage does not have it (not_found). `onBegun` returning false (the file was deleted meanwhile) stops
 * after the row is made, answering null. Throws an Error named by the failure code.
 */
export async function storeFile(
  known: { uploadId: string | null; path: string | null },
  steps: StoreSteps,
  onBegun: (uploadId: string, path: string) => boolean = () => true,
): Promise<{ uploadId: string; path: string } | null> {
  let { uploadId, path } = known;
  if (uploadId && path) {
    const again = await steps.stored(uploadId);
    if (again.ok) return { uploadId, path };
    if (again.code !== "not_found") throw new Error(again.code ?? "internal");
  } else {
    ({ uploadId, path } = await steps.begin());
    if (!onBegun(uploadId, path)) return null;
  }
  await steps.upload(path);
  const r = await steps.stored(uploadId);
  if (!r.ok) throw new Error(r.code ?? "internal");
  return { uploadId, path };
}

/** Submit is offered once there is a file and every file is uploaded. */
export function canSubmit(files: { state: string }[]): boolean {
  return files.length > 0 && files.every((f) => f.state === "stored");
}

/** Whether the strip holds answers that are not handed in (Ruling R40): files still on their way ("uploading"), or
 * files uploaded and waiting for Submit ("not_sent"). The screen warns for both, and before the page is left. */
export function unsentFiles(files: { state: string }[]): "none" | "uploading" | "not_sent" {
  if (files.some((f) => f.state === "waiting" || f.state === "uploading")) return "uploading";
  return files.some((f) => f.state === "stored") ? "not_sent" : "none";
}

/** "2, 3, 4 and 6" */
export function pageList(pages: number[]): string {
  if (pages.length <= 1) return pages.join("");
  return `${pages.slice(0, -1).join(", ")} and ${pages[pages.length - 1]}`;
}
