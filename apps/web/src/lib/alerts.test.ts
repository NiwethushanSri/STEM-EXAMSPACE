import { describe, expect, it } from "vitest";
import { QUEUE_STUCK_MINUTES, parseScriptsDashboard, scriptsDashboardAlerts, type ScriptsDashboard } from "@/lib/alerts";

const EXAM = "11111111-1111-4111-8111-111111111111";
const CENTRE = "22222222-2222-4222-8222-222222222222";

const answer = {
  ok: true,
  now: "2026-12-02T12:00:00Z",
  exams: [
    {
      exam: { id: EXAM, title: "Maths mock", paper: "Paper 1", starts_at: "2026-12-01T09:00:00Z" },
      expected: 40,
      received: 38,
      verified: 30,
      needs_attention: 5,
      late: 2,
      unsubmitted: 1,
    },
  ],
  unsubmitted_drafts: 1,
  open_exceptions: 7,
  failed_jobs: 1,
  oldest_queued_minutes: 3,
  stuck_jobs: 0,
  centres_without_scanned_custody: [
    {
      exam_id: EXAM,
      title: "Maths mock",
      paper: "Paper 1",
      starts_at: "2026-12-01T09:00:00Z",
      centre_id: CENTRE,
      venue: "Town Hall",
      room: "Room 2",
      counted: 12,
      scanned_by: "2026-12-02T09:00:00Z",
    },
  ],
};

describe("parseScriptsDashboard", () => {
  it("reads the dashboard answer", () => {
    expect(parseScriptsDashboard(answer)).toEqual({
      exams: [
        { id: EXAM, title: "Maths mock", paper: "Paper 1", startsAt: "2026-12-01T09:00:00Z", expected: 40, received: 38, verified: 30, needsAttention: 5, late: 2, unsubmitted: 1 },
      ],
      unsubmittedDrafts: 1,
      openExceptions: 7,
      failedJobs: 1,
      oldestQueuedMinutes: 3,
      stuckJobs: 0,
      centresNotScanned: [
        { examId: EXAM, title: "Maths mock", paper: "Paper 1", centreId: CENTRE, venue: "Town Hall", room: "Room 2", counted: 12, scannedBy: "2026-12-02T09:00:00Z" },
      ],
    });
  });

  it("is null for a refusal or a broken answer", () => {
    expect(parseScriptsDashboard({ ok: false, code: "forbidden" })).toBeNull();
    expect(parseScriptsDashboard(null)).toBeNull();
    expect(parseScriptsDashboard([answer])).toBeNull();
  });

  it("leaves out malformed rows and reads missing counts as 0 and no queue as null", () => {
    const d = parseScriptsDashboard({
      ok: true,
      exams: [{ exam: { id: 5 } }, { exam: { id: EXAM, title: "T", starts_at: "2026-12-01T09:00:00Z" }, expected: -1, received: "3" }],
      oldest_queued_minutes: null,
      centres_without_scanned_custody: [{ exam_id: EXAM }],
    });
    expect(d).toEqual({
      exams: [{ id: EXAM, title: "T", paper: null, startsAt: "2026-12-01T09:00:00Z", expected: 0, received: 0, verified: 0, needsAttention: 0, late: 0, unsubmitted: 0 }],
      unsubmittedDrafts: 0,
      openExceptions: 0,
      failedJobs: 0,
      oldestQueuedMinutes: null,
      stuckJobs: 0,
      centresNotScanned: [],
    });
  });
});

describe("scriptsDashboardAlerts", () => {
  const base: ScriptsDashboard = { exams: [], unsubmittedDrafts: 0, openExceptions: 0, failedJobs: 0, oldestQueuedMinutes: null, stuckJobs: 0, centresNotScanned: [] };

  it("says nothing when all is well", () => {
    expect(scriptsDashboardAlerts(base)).toEqual([]);
    expect(scriptsDashboardAlerts({ ...base, oldestQueuedMinutes: QUEUE_STUCK_MINUTES - 1 })).toEqual([]);
  });

  it("names a stuck queue, failed files, centres not scanned and open problems, the most urgent first", () => {
    const d = parseScriptsDashboard({ ...answer, oldest_queued_minutes: 42, failed_jobs: 2, open_exceptions: 1 })!;
    expect(scriptsDashboardAlerts(d)).toEqual([
      {
        id: "queue",
        tone: "red",
        text: "Files have waited 42 minutes to be processed. Check that the processing server is running.",
        href: null,
      },
      { id: "failed", tone: "red", text: "2 files could not be processed. They are in the exception queue.", href: "/admin/scripts/exceptions?kind=processing_failed" },
      {
        id: "unsent",
        tone: "red",
        text: "1 family uploaded pages but did not press Submit. Their answers were not handed in.",
        href: "/admin/scripts/unsent",
      },
      {
        id: `custody-${EXAM}-${CENTRE}`,
        tone: "amber",
        text: "Maths mock (Paper 1), Town Hall, Room 2: sheets were collected for 12 candidates but no scan is recorded. It was due by Wed 2 Dec 2026, 09:00.",
        href: `/admin/exams/${EXAM}`,
      },
      { id: "open", tone: "amber", text: "1 problem is waiting in the exception queue.", href: "/admin/scripts/exceptions" },
    ]);
  });

  it("names a server that stopped part-way through a file, and reads the count", () => {
    expect(parseScriptsDashboard({ ...answer, oldest_queued_minutes: 40, stuck_jobs: 1 })?.stuckJobs).toBe(1);
    expect(scriptsDashboardAlerts({ ...base, oldestQueuedMinutes: 40, stuckJobs: 1 })).toEqual([
      {
        id: "queue",
        tone: "red",
        text: "1 file stopped part-way through processing, and files have waited 40 minutes. Check that the processing server is running.",
        href: null,
      },
    ]);
    expect(scriptsDashboardAlerts({ ...base, oldestQueuedMinutes: 16, stuckJobs: 2 })[0].text).toBe(
      "2 files stopped part-way through processing, and files have waited 16 minutes. Check that the processing server is running.",
    );
  });

  it("counts the families who uploaded pages but never submitted (Ruling R40)", () => {
    expect(scriptsDashboardAlerts({ ...base, unsubmittedDrafts: 3 })).toEqual([
      { id: "unsent", tone: "red", text: "3 families uploaded pages but did not press Submit. Their answers were not handed in.", href: "/admin/scripts/unsent" },
    ]);
  });

  it("uses the singular for one file and one candidate, and the plural for problems", () => {
    const d: ScriptsDashboard = {
      ...base,
      failedJobs: 1,
      openExceptions: 3,
      centresNotScanned: [{ examId: EXAM, title: "Physics", paper: null, centreId: CENTRE, venue: "Hall", room: "R1", counted: 1, scannedBy: "2026-07-02T08:00:00Z" }],
    };
    expect(scriptsDashboardAlerts(d).map((a) => a.text)).toEqual([
      "1 file could not be processed. It is in the exception queue.",
      "Physics, Hall, R1: sheets were collected for 1 candidate but no scan is recorded. It was due by Thu 2 Jul 2026, 09:00.",
      "3 problems are waiting in the exception queue.",
    ]);
  });
});
