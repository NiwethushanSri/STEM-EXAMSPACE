import { describe, expect, it } from "vitest";
import {
  MAX_FILES,
  UPLOAD_TEXT,
  attentionItems,
  blankPrompt,
  canSubmit,
  fileProblem,
  retakePrompt,
  statusWord,
  uploadFileType,
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
});
