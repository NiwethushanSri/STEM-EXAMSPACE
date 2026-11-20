import { describe, expect, it } from "vitest";
import {
  SCAN_MAX_BYTES,
  SCAN_POLL_MS,
  completeSummary,
  isProcessing,
  parseCompleteResult,
  parseScanStatus,
  scanFileProblem,
  scanFileType,
  totalsLine,
} from "./scan-batch";

const raw = {
  ok: true,
  batch_id: "11111111-1111-4111-8111-111111111111",
  number: "B-MATH-P1-001",
  exam_id: "22222222-2222-4222-8222-222222222222",
  centre_id: "33333333-3333-4333-8333-333333333333",
  manifest: "M-MATH-P1-01",
  created_at: "2031-06-07T12:00:00Z",
  submitted_at: null,
  uploads: [
    { id: "44444444-4444-4444-8444-444444444444", state: "stored", byte_size: 1000, mime: "application/pdf" },
    { id: 5, state: "stored", byte_size: 1 },
  ],
  totals: { pages: 12, matched: 7, blank: 1, flagged: 4, duplicates: 1 },
  jobs: { queued: 2, running: 1, failed: 0 },
  candidates_complete: 2,
  candidates_expected: 4,
};

describe("parseScanStatus", () => {
  it("reads what scan_batch_status answers", () => {
    const s = parseScanStatus(raw);
    expect(s).toEqual({
      id: raw.batch_id,
      number: "B-MATH-P1-001",
      centreId: raw.centre_id,
      manifest: "M-MATH-P1-01",
      createdAt: "2031-06-07T12:00:00Z",
      submittedAt: null,
      uploads: [{ id: "44444444-4444-4444-8444-444444444444", state: "stored", byteSize: 1000 }],
      totals: { pages: 12, matched: 7, blank: 1, flagged: 4, duplicates: 1 },
      jobs: { queued: 2, running: 1, failed: 0 },
      candidatesComplete: 2,
      candidatesExpected: 4,
    });
  });
  it("refuses a failure or a broken answer", () => {
    expect(parseScanStatus({ ok: false, code: "forbidden" })).toBeNull();
    expect(parseScanStatus(null)).toBeNull();
    expect(parseScanStatus([raw])).toBeNull();
    expect(parseScanStatus({ ...raw, number: 3 })).toBeNull();
  });
  it("reads missing counts as zero", () => {
    const s = parseScanStatus({ ...raw, totals: null, jobs: {}, manifest: null, candidates_complete: "x" });
    expect(s?.totals).toEqual({ pages: 0, matched: 0, blank: 0, flagged: 0, duplicates: 0 });
    expect(s?.jobs).toEqual({ queued: 0, running: 0, failed: 0 });
    expect(s?.manifest).toBeNull();
    expect(s?.candidatesComplete).toBe(0);
  });
});

describe("isProcessing", () => {
  it("is true while a job waits or runs", () => {
    const s = parseScanStatus(raw)!;
    expect(isProcessing(s)).toBe(true);
    expect(isProcessing({ ...s, jobs: { queued: 0, running: 1, failed: 0 } })).toBe(true);
    expect(isProcessing({ ...s, jobs: { queued: 0, running: 0, failed: 3 } })).toBe(false);
  });
  it("polls every 3 seconds", () => {
    expect(SCAN_POLL_MS).toBe(3000);
  });
});

describe("scanFileType", () => {
  it("takes PDF, JPEG and PNG by type or by name", () => {
    expect(scanFileType("scan.pdf", "application/pdf")).toBe("application/pdf");
    expect(scanFileType("SCAN.PDF", "")).toBe("application/pdf");
    expect(scanFileType("page.jpeg", "")).toBe("image/jpeg");
    expect(scanFileType("page.JPG", "image/jpeg")).toBe("image/jpeg");
    expect(scanFileType("page.png", "image/png")).toBe("image/png");
  });
  it("refuses anything else", () => {
    expect(scanFileType("photo.heic", "image/heic")).toBeNull();
    expect(scanFileType("notes.txt", "text/plain")).toBeNull();
    expect(scanFileType("scan.pdf", "text/plain")).toBeNull();
  });
});

describe("scanFileProblem", () => {
  it("takes files up to 1 GB", () => {
    expect(SCAN_MAX_BYTES).toBe(1073741824);
    expect(scanFileProblem(1)).toBeNull();
    expect(scanFileProblem(SCAN_MAX_BYTES)).toBeNull();
    expect(scanFileProblem(SCAN_MAX_BYTES + 1)).toBe("file_too_large");
    expect(scanFileProblem(0)).toBe("invalid_input");
  });
});

describe("totalsLine", () => {
  it("says what the pages are", () => {
    expect(totalsLine(parseScanStatus(raw)!.totals)).toBe("12 pages: 7 matched, 1 blank, 4 flagged, 1 duplicate");
    expect(totalsLine({ pages: 1, matched: 1, blank: 0, flagged: 0, duplicates: 2 })).toBe("1 page: 1 matched, 0 blank, 0 flagged, 2 duplicates");
  });
});

describe("completeSummary", () => {
  it("reads scan_centre_complete's counts", () => {
    expect(parseCompleteResult({ ok: true, candidates: 4, complete: 2, missing: 2 })).toEqual({ candidates: 4, complete: 2, missing: 2 });
    expect(parseCompleteResult({ ok: false, code: "still_processing" })).toBeNull();
  });
  it("says how many candidates are complete and how many miss pages", () => {
    expect(completeSummary({ candidates: 4, complete: 2, missing: 2 })).toBe(
      "4 candidates: 2 complete, 2 with missing pages. The missing pages are in the exception queue.",
    );
    expect(completeSummary({ candidates: 1, complete: 1, missing: 0 })).toBe("1 candidate: 1 complete.");
    expect(completeSummary({ candidates: 0, complete: 0, missing: 0 })).toBe("No candidate was marked present or late at this centre.");
  });
});
