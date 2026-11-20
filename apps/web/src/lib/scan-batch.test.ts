import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  SCAN_MAX_BYTES,
  SCAN_POLL_MS,
  SCAN_POLL_MAX_FAILURES,
  completeFailureMessage,
  completeSummary,
  hasUploadsInFlight,
  isProcessing,
  parseCompleteResult,
  parseScanStatus,
  scanFileProblem,
  scanFileType,
  startPolling,
  totalsLine,
} from "./scan-batch";

const raw = {
  ok: true,
  batch_id: "11111111-1111-4111-8111-111111111111",
  number: "B-MATH-P1-01",
  exam_id: "22222222-2222-4222-8222-222222222222",
  centre_id: "33333333-3333-4333-8333-333333333333",
  manifest: "M-MATH-P1-01",
  created_at: "2031-06-07T12:00:00Z",
  submitted_at: null,
  uploads: [
    { id: "44444444-4444-4444-8444-444444444444", state: "stored", byte_size: 1000, mime: "application/pdf" },
    { id: 5, state: "stored", byte_size: 1 },
  ],
  totals: { pages: 12, matched: 6, blank: 1, flagged: 3, duplicates: 1, set_aside: 1, accepted: 2 },
  jobs: { queued: 2, running: 1, failed: 0 },
  candidates_complete: 2,
  candidates_expected: 4,
};

describe("parseScanStatus", () => {
  it("reads what scan_batch_status answers", () => {
    const s = parseScanStatus(raw);
    expect(s).toEqual({
      id: raw.batch_id,
      number: "B-MATH-P1-01",
      centreId: raw.centre_id,
      manifest: "M-MATH-P1-01",
      createdAt: "2031-06-07T12:00:00Z",
      submittedAt: null,
      uploads: [{ id: "44444444-4444-4444-8444-444444444444", state: "stored", byteSize: 1000 }],
      totals: { pages: 12, matched: 6, blank: 1, flagged: 3, duplicates: 1, setAside: 1, accepted: 2 },
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
    expect(s?.totals).toEqual({ pages: 0, matched: 0, blank: 0, flagged: 0, duplicates: 0, setAside: 0, accepted: 0 });
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
});

describe("hasUploadsInFlight", () => {
  const files = [
    { batchId: "a", state: "stored" },
    { batchId: "b", state: "uploading" },
    { batchId: "c", state: "waiting" },
    { batchId: "d", state: "failed" },
  ];
  it("is true while a file of these batches waits or uploads", () => {
    expect(hasUploadsInFlight(files, ["a", "b"])).toBe(true);
    expect(hasUploadsInFlight(files, ["c"])).toBe(true);
  });
  it("is false once every file is uploaded or has failed", () => {
    expect(hasUploadsInFlight(files, ["a", "d"])).toBe(false);
    expect(hasUploadsInFlight(files, [])).toBe(false);
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
  it("names each page once, so the numbers add up to the pages", () => {
    expect(totalsLine(parseScanStatus(raw)!.totals)).toBe("12 pages: 6 matched, 1 blank, 1 duplicate, 3 to check, 1 set aside");
    expect(totalsLine({ pages: 3, matched: 1, blank: 0, flagged: 0, duplicates: 2, setAside: 0, accepted: 0 })).toBe(
      "3 pages: 1 matched, 0 blank, 2 duplicates, 0 to check",
    );
    expect(totalsLine({ pages: 1, matched: 1, blank: 0, flagged: 0, duplicates: 0, setAside: 0, accepted: 0 })).toBe(
      "1 page: 1 matched, 0 blank, 0 duplicates, 0 to check",
    );
  });
});

describe("completeSummary", () => {
  it("reads scan_centre_complete's counts", () => {
    expect(parseCompleteResult({ ok: true, candidates: 4, complete: 2, missing: 1, mixed: 1 })).toEqual({ candidates: 4, complete: 2, missing: 1, mixed: 1 });
    expect(parseCompleteResult({ ok: true, candidates: 1, complete: 1, missing: 0 })).toEqual({ candidates: 1, complete: 1, missing: 0, mixed: 0 });
    expect(parseCompleteResult({ ok: false, code: "still_processing" })).toBeNull();
  });
  it("says how many candidates are complete and why the others are not", () => {
    expect(completeSummary({ candidates: 4, complete: 2, missing: 2, mixed: 0 })).toBe(
      "4 candidates: 2 complete, 2 with missing pages. These are in the exception queue.",
    );
    expect(completeSummary({ candidates: 3, complete: 1, missing: 1, mixed: 1 })).toBe(
      "3 candidates: 1 complete, 1 with missing pages, 1 with pages from two paper versions. These are in the exception queue.",
    );
    expect(completeSummary({ candidates: 1, complete: 1, missing: 0, mixed: 0 })).toBe("1 candidate: 1 complete.");
    expect(completeSummary({ candidates: 0, complete: 0, missing: 0, mixed: 0 })).toBe("No candidate was marked present or late at this centre.");
  });
  it("asks for the register first, with how many are not marked", () => {
    expect(completeFailureMessage({ ok: false, code: "register_incomplete", not_marked: 3 })).toBe(
      "Mark every candidate on the register first (3 not marked).",
    );
    expect(completeFailureMessage({ ok: false, code: "register_incomplete" })).toBe("Mark every candidate on the register first.");
    expect(completeFailureMessage({ ok: false, code: "still_processing" })).toContain("still uploading or being processed");
    expect(completeFailureMessage(null)).toBe("Something went wrong. Please try again.");
  });
});

describe("startPolling", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it("polls every 3 seconds, never two at once", async () => {
    expect(SCAN_POLL_MS).toBe(3000);
    let running = 0;
    let most = 0;
    let calls = 0;
    const tick = () => {
      calls++;
      running++;
      most = Math.max(most, running);
      // Each answer takes longer than the interval.
      return new Promise<boolean>((resolve) => setTimeout(() => { running--; resolve(true); }, 5000));
    };
    const stop = startPolling(tick, { intervalMs: SCAN_POLL_MS, maxFailures: SCAN_POLL_MAX_FAILURES, onGiveUp: () => undefined });
    await vi.advanceTimersByTimeAsync(2999);
    expect(calls).toBe(0);
    await vi.advanceTimersByTimeAsync(1);
    expect(calls).toBe(1);
    await vi.advanceTimersByTimeAsync(7000);
    expect(calls).toBe(1);
    await vi.advanceTimersByTimeAsync(1000);
    expect(calls).toBe(2);
    expect(most).toBe(1);
    stop();
  });

  it("gives up after 3 failures in a row; a success starts the count again", async () => {
    const answers = [false, false, true, false, false, false, true];
    let calls = 0;
    const onGiveUp = vi.fn();
    startPolling(async () => answers[calls++] ?? true, { intervalMs: 100, maxFailures: SCAN_POLL_MAX_FAILURES, onGiveUp });
    await vi.advanceTimersByTimeAsync(1000);
    expect(SCAN_POLL_MAX_FAILURES).toBe(3);
    expect(calls).toBe(6);
    expect(onGiveUp).toHaveBeenCalledTimes(1);
  });

  it("counts a thrown error as a failure", async () => {
    const onGiveUp = vi.fn();
    startPolling(() => Promise.reject(new Error("offline")), { intervalMs: 100, maxFailures: 3, onGiveUp });
    await vi.advanceTimersByTimeAsync(1000);
    expect(onGiveUp).toHaveBeenCalledTimes(1);
  });

  it("stops when asked, even with an answer on its way", async () => {
    let calls = 0;
    let finish: (ok: boolean) => void = () => undefined;
    const onGiveUp = vi.fn();
    const stop = startPolling(() => {
      calls++;
      return new Promise<boolean>((resolve) => { finish = resolve; });
    }, { intervalMs: 100, maxFailures: 3, onGiveUp });
    await vi.advanceTimersByTimeAsync(100);
    stop();
    finish(false);
    await vi.advanceTimersByTimeAsync(1000);
    expect(calls).toBe(1);
    expect(onGiveUp).not.toHaveBeenCalled();
  });
});
