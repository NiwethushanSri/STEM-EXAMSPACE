import { describe, expect, it } from "vitest";
import {
  MAX_FILES,
  UPLOAD_TEXT,
  afterSubmit,
  attentionItems,
  blankPrompt,
  canSubmit,
  unsentFiles,
  unsentWarning,
  fileProblem,
  isStale,
  retakePrompt,
  statusWord,
  storeFile,
  uploadFileType,
  uploadView,
  type HomeUploadStatus,
} from "./home-upload";

const status = (over: Partial<HomeUploadStatus> = {}): HomeUploadStatus => ({
  submission: null,
  pages: [],
  missing: [],
  retake: [],
  unplaced: [],
  failed: [],
  blank: [],
  script: null,
  copy_pages: 6,
  draft: null,
  ...over,
});
const sub = (state: string, late = false) =>
  ({ id: "s-1", seq: 1, state, late, submitted_at: "2031-06-07T11:00:00Z", checked_at: null, replaces_all: true }) as HomeUploadStatus["submission"];

describe("the words a family sees", () => {
  it("statuses and prompts are exactly the agreed words", () => {
    expect([UPLOAD_TEXT.uploading, UPLOAD_TEXT.checking, UPLOAD_TEXT.received, UPLOAD_TEXT.attention, UPLOAD_TEXT.late, UPLOAD_TEXT.rejected]).toEqual([
      "Uploading",
      "Checking your pages",
      "Received",
      "Needs your attention",
      "Submitted late",
      "Rejected",
    ]);
    expect(blankPrompt(6)).toBe("Was page 6 left blank?");
    expect(retakePrompt(4)).toBe("Retake page 4");
    expect(UPLOAD_TEXT.receiptHeading).toBe("We have received your answers");
    expect(UPLOAD_TEXT.photoAdvice).toBe("Photograph each page on its own, flat, from directly above, on a plain dark surface.");
    expect(UPLOAD_TEXT.blurred).toBe("This photo is blurred. Retake it?");
  });

  it("never says Received before the server does", () => {
    expect(statusWord(status().submission)).toBeNull();
    expect(statusWord(sub("draft"))).toBeNull();
    expect(statusWord(sub("checking"))).toBe("Checking your pages");
    expect(statusWord(sub("checking", true))).toBe("Checking your pages");
    expect(statusWord(sub("needs_attention"))).toBe("Needs your attention");
    expect(statusWord(sub("received"))).toBe("Received");
    expect(statusWord(sub("received", true))).toBe("Submitted late");
    expect(statusWord(sub("rejected"))).toBe("Rejected");
    expect(statusWord(sub("something new"))).toBeNull();
  });
});

describe("attentionItems", () => {
  it("lists what keeps the answers from being received, in page order", () => {
    const s = status({
      submission: sub("needs_attention"),
      retake: [{ page_id: "p-4", copy_page: 4, flags: ["blurred"] }],
      missing: [6],
      unplaced: [{ page_id: "p-x", upload_id: "u-2", source_index: 2, file_number: 2 }],
      failed: [3],
    });
    expect(attentionItems(s)).toEqual([
      { kind: "retake", pageId: "p-4", page: 4, reason: "It is blurred." },
      { kind: "missing", page: 6 },
      { kind: "unplaced", pageId: "p-x", file: 2, sourcePage: 3 },
      { kind: "failed", file: 3 },
    ]);
  });

  it("says why a page needs retaking", () => {
    const reason = (flags: string[]) =>
      (attentionItems(status({ submission: sub("needs_attention"), retake: [{ page_id: "p", copy_page: 2, flags }] }))[0] as { reason: string }).reason;
    expect(reason(["dark"])).toBe("It is too dark.");
    expect(reason(["cut_off"])).toBe("Part of the page is cut off.");
    expect(reason(["layout_unexpected"])).toContain("on its own");
    expect(reason([])).toBe("It could not be read clearly.");
    expect(reason(["blurred", "dark"])).toBe("It is blurred. It is too dark.");
  });

  it("is empty unless the answers need attention", () => {
    for (const state of ["checking", "received", "rejected"]) {
      expect(attentionItems(status({ submission: sub(state), missing: [6] }))).toEqual([]);
    }
  });
});

describe("files", () => {
  it("works out the kind and type, from the name when the browser gives none", () => {
    expect(uploadFileType("scan.pdf", "application/pdf")).toEqual({ kind: "home_pdf", mime: "application/pdf" });
    expect(uploadFileType("IMG_0001.JPG", "image/jpeg")).toEqual({ kind: "home_photo", mime: "image/jpeg" });
    expect(uploadFileType("IMG_0002.HEIC", "")).toEqual({ kind: "home_photo", mime: "image/heic" });
    expect(uploadFileType("photo.heif", "application/octet-stream")).toEqual({ kind: "home_photo", mime: "image/heif" });
    expect(uploadFileType("page.png", "image/png")).toEqual({ kind: "home_photo", mime: "image/png" });
    expect(uploadFileType("notes.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document")).toBeNull();
    expect(uploadFileType("anim.gif", "image/gif")).toBeNull();
    expect(uploadFileType("noextension", "")).toBeNull();
  });

  it("checks the size limits before uploading", () => {
    expect(fileProblem("home_photo", 25 * 1024 * 1024)).toBeNull();
    expect(fileProblem("home_photo", 25 * 1024 * 1024 + 1)).toBe("file_too_large");
    expect(fileProblem("home_pdf", 100 * 1024 * 1024)).toBeNull();
    expect(fileProblem("home_pdf", 100 * 1024 * 1024 + 1)).toBe("file_too_large");
    expect(fileProblem("home_photo", 0)).toBe("invalid_input");
    expect(MAX_FILES).toBe(60);
  });

  it("allows Submit once every file is uploaded", () => {
    expect(canSubmit([])).toBe(false);
    expect(canSubmit([{ state: "stored" }])).toBe(true);
    expect(canSubmit([{ state: "stored" }, { state: "uploading" }])).toBe(false);
    expect(canSubmit([{ state: "stored" }, { state: "failed" }])).toBe(false);
    expect(canSubmit([{ state: "waiting" }])).toBe(false);
  });

  it("warns while uploaded pages are not sent, and while files are still on their way (Ruling R40)", () => {
    expect(unsentFiles([])).toBe("none");
    expect(unsentFiles([{ state: "failed" }])).toBe("none");
    expect(unsentFiles([{ state: "stored" }])).toBe("not_sent");
    expect(unsentFiles([{ state: "stored" }, { state: "failed" }])).toBe("not_sent");
    expect(unsentFiles([{ state: "stored" }, { state: "uploading" }])).toBe("uploading");
    expect(unsentFiles([{ state: "waiting" }])).toBe("uploading");
    expect(UPLOAD_TEXT.notSent).toBe("Your pages are not sent yet. Press Submit to send them.");
    expect(UPLOAD_TEXT.notSentUploading).toContain("not sent yet");
  });
});

describe("after a replacement submit", () => {
  const received = status({
    submission: sub("received"),
    script: { number: "S-X-0001", state: "verified", pages: [2, 3, 4] },
    blank: [5],
    draft: { id: "d-2", seq: 2, replaces_all: false, uploads: [] },
  });
  const result = { submission_id: "s-2", seq: 2, state: "checking", late: false, submitted_at: "2031-06-07T13:00:00Z" };

  it("shows the server's answer to the submit, never the earlier Received", () => {
    const next = afterSubmit(received, result);
    expect(next.submission).toMatchObject({ id: "s-2", seq: 2, state: "checking", late: false, submitted_at: "2031-06-07T13:00:00Z" });
    expect(statusWord(next.submission)).toBe("Checking your pages");
    expect(uploadView(next, { canUpload: true, editing: false })).toEqual({ editor: false, receipt: false });
    expect(next.draft).toBeNull();
    expect([next.missing, next.retake, next.unplaced, next.failed, next.pages]).toEqual([[], [], [], [], []]);
    // The view before the submit did show the receipt.
    expect(uploadView(received, { canUpload: true, editing: false })).toEqual({ editor: false, receipt: true });
  });

  it("ignores a status older than the submission handed in (a reply to a request sent before the submit)", () => {
    expect(isStale(received, 2)).toBe(true);
    expect(isStale(afterSubmit(received, result), 2)).toBe(false);
    expect(isStale(status({ submission: { ...sub("received")!, seq: 3 } }), 2)).toBe(false);
    expect(isStale(status(), 2)).toBe(true);
    expect(isStale(received, null)).toBe(false);
  });

  it("shows the editor for a first upload or while replacing, only when uploads are open", () => {
    expect(uploadView(status(), { canUpload: true, editing: false })).toEqual({ editor: true, receipt: false });
    expect(uploadView(status(), { canUpload: false, editing: false })).toEqual({ editor: false, receipt: false });
    expect(uploadView(received, { canUpload: true, editing: true })).toEqual({ editor: true, receipt: false });
  });
});

describe("storeFile", () => {
  /** Fake steps that record what happened; `stored` answers in turn from `answers`. */
  function steps(answers: { ok: boolean; code?: string }[]) {
    const log: string[] = [];
    return {
      log,
      begin: async () => {
        log.push("begin");
        return { uploadId: "u-new", path: "home/b/u-new.jpg" };
      },
      upload: async (path: string) => {
        log.push("upload " + path);
      },
      stored: async (id: string) => {
        log.push("stored " + id);
        return answers.shift() ?? { ok: true };
      },
    };
  }

  it("begins, uploads and stores a new file", async () => {
    const s = steps([{ ok: true }]);
    expect(await storeFile({ uploadId: null, path: null }, s)).toEqual({ uploadId: "u-new", path: "home/b/u-new.jpg" });
    expect(s.log).toEqual(["begin", "upload home/b/u-new.jpg", "stored u-new"]);
  });

  it("a retry after the upload went through only asks again (no second upload, which storage would refuse)", async () => {
    const s = steps([{ ok: true }]);
    await storeFile({ uploadId: "u-1", path: "home/b/u-1.jpg" }, s);
    expect(s.log).toEqual(["stored u-1"]);
  });

  it("a retry uploads again only when storage does not have the file", async () => {
    const s = steps([{ ok: false, code: "not_found" }, { ok: true }]);
    await storeFile({ uploadId: "u-1", path: "home/b/u-1.jpg" }, s);
    expect(s.log).toEqual(["stored u-1", "upload home/b/u-1.jpg", "stored u-1"]);
  });

  it("a file storage has with the wrong size is not sent again", async () => {
    const s = steps([{ ok: false, code: "invalid_input" }]);
    await expect(storeFile({ uploadId: "u-1", path: "home/b/u-1.jpg" }, s)).rejects.toThrow("invalid_input");
    expect(s.log).toEqual(["stored u-1"]);
  });

  it("stops after begin when the file was deleted meanwhile", async () => {
    const s = steps([]);
    expect(await storeFile({ uploadId: null, path: null }, s, () => false)).toBeNull();
    expect(s.log).toEqual(["begin"]);
  });

  it("a refused stored call fails with its code", async () => {
    const s = steps([{ ok: false, code: "invalid_input" }]);
    await expect(storeFile({ uploadId: null, path: null }, s)).rejects.toThrow("invalid_input");
  });
});

describe("the warning that pages are not sent", () => {
  it("unsent_warning_only_while_submit_is_possible", () => {
    for (const phase of ["sitting", "upload_open", "late_window"] as const) {
      expect(unsentWarning(phase, 1)).toBe("press_submit");
      expect(unsentWarning(phase, 0)).toBeNull();
    }
    expect(unsentWarning("closed", 2)).toBe("closed_unsent");
    expect(unsentWarning("closed", 0)).toBeNull();
    expect(unsentWarning("before_start", 3)).toBeNull();
  });

  it("says the upload time has ended when it has", () => {
    expect(UPLOAD_TEXT.closedUnsent).toBe("The upload time has ended. Your pages were not sent. Please contact the institution.");
  });
});
