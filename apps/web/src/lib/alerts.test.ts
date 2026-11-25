import { describe, expect, it } from "vitest";
import {
  QUEUE_STUCK_MINUTES,
  checkingAlerts,
  markingAlerts,
  parseMarkingDashboard,
  parseScriptsDashboard,
  scriptsDashboardAlerts,
  type MarkingDashboard,
  type ScriptsDashboard,
} from "@/lib/alerts";

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

/** A marking dashboard with nothing to count. */
const NONE: MarkingDashboard = {
  exams: [],
  left: 0,
  onHold: 0,
  overdueExams: 0,
  alertsOpen: 0,
  picturesToCheck: 0,
  staleAssigned: 0,
  withLead: 0,
  waitingSecond: 0,
  stuckSecond: 0,
  markersPaused: 0,
  readyToApprove: 0,
  approvedStale: 0,
};

describe("parseMarkingDashboard", () => {
  const marking = {
    ok: true,
    exams: [
      {
        exam_id: EXAM,
        title: "Maths mock",
        paper: "Paper 1",
        deadline: "2026-12-12T17:00:00Z",
        overdue: true,
        left: 12,
        marked: 30,
        on_hold: 2,
        checked: 20,
        with_lead: 3,
        waiting_second: 4,
        approved: false,
      },
      { exam_id: CENTRE, title: "Physics", paper: null, deadline: null, overdue: false, left: 0, marked: 8, on_hold: 0, checked: 8, with_lead: 0, waiting_second: 0, approved: true },
    ],
    totals: {
      left: 12,
      on_hold: 2,
      overdue_exams: 1,
      alerts_open: 3,
      pictures_to_check: 4,
      stale_assigned: 5,
      with_lead: 3,
      waiting_second: 4,
      stuck_second: 1,
      markers_paused: 2,
      ready_to_approve: 1,
      approved_stale: 1,
    },
  };

  it("reads the marking figures, with the checks", () => {
    expect(parseMarkingDashboard(marking)).toEqual({
      exams: [
        {
          examId: EXAM,
          title: "Maths mock",
          paper: "Paper 1",
          deadline: "2026-12-12T17:00:00Z",
          overdue: true,
          left: 12,
          marked: 30,
          onHold: 2,
          checked: 20,
          withLead: 3,
          waitingSecond: 4,
          approved: false,
        },
        { examId: CENTRE, title: "Physics", paper: null, deadline: null, overdue: false, left: 0, marked: 8, onHold: 0, checked: 8, withLead: 0, waitingSecond: 0, approved: true },
      ],
      left: 12,
      onHold: 2,
      overdueExams: 1,
      alertsOpen: 3,
      picturesToCheck: 4,
      staleAssigned: 5,
      withLead: 3,
      waitingSecond: 4,
      stuckSecond: 1,
      markersPaused: 2,
      readyToApprove: 1,
      approvedStale: 1,
    });
  });

  it("is null for a refusal or a broken answer, and leaves out malformed rows", () => {
    expect(parseMarkingDashboard({ ok: false, code: "forbidden" })).toBeNull();
    expect(parseMarkingDashboard(null)).toBeNull();
    expect(parseMarkingDashboard({ ok: true, exams: [{ exam_id: 5 }, { exam_id: EXAM, title: "T", left: -1, overdue: "yes", approved: "yes" }] })).toEqual({
      ...NONE,
      exams: [{ examId: EXAM, title: "T", paper: null, deadline: null, overdue: false, left: 0, marked: 0, onHold: 0, checked: 0, withLead: 0, waitingSecond: 0, approved: false }],
    });
  });
});

describe("markingAlerts", () => {
  const none: MarkingDashboard = NONE;

  it("marking_alerts_texts: overdue exams, scripts on hold, pictures to check and untouched assigned scripts, the most urgent first", () => {
    expect(markingAlerts(none)).toEqual([]);
    expect(markingAlerts({ ...none, left: 40, alertsOpen: 2 })).toEqual([]);
    expect(markingAlerts({ ...none, overdueExams: 2, onHold: 3, picturesToCheck: 4, staleAssigned: 5 })).toEqual([
      { id: "marking-overdue", tone: "red", text: "Marking is overdue for 2 exams.", href: "/admin/marking" },
      { id: "marking-on-hold", tone: "amber", text: "3 scripts are on hold in marking.", href: "/admin/marking" },
      { id: "marking-pictures", tone: "amber", text: "4 marking pictures wait to be checked.", href: "/admin/scripts/exceptions?tab=checks" },
      { id: "marking-stale", tone: "amber", text: "5 assigned scripts have not been touched for a week.", href: "/admin/marking" },
    ]);
  });

  it("uses the singular for one", () => {
    expect(markingAlerts({ ...none, overdueExams: 1, onHold: 1, picturesToCheck: 1, staleAssigned: 1 }).map((a) => a.text)).toEqual([
      "Marking is overdue for 1 exam.",
      "1 script is on hold in marking.",
      "1 marking picture waits to be checked.",
      "1 assigned script has not been touched for a week.",
    ]);
  });
});

describe("checkingAlerts", () => {
  it("checking_alerts_texts: a stale approval, stuck scripts, scripts with the lead, paused markers and exams ready to approve, the most urgent first", () => {
    expect(checkingAlerts(NONE)).toEqual([]);
    // Scripts waiting for a second marker whom somebody can be are not an alert, nor are 3A's figures.
    expect(checkingAlerts({ ...NONE, waitingSecond: 6, overdueExams: 1, onHold: 2 })).toEqual([]);
    expect(checkingAlerts({ ...NONE, approvedStale: 2, stuckSecond: 3, withLead: 4, markersPaused: 5, readyToApprove: 6 })).toEqual([
      { id: "checking-stale", tone: "red", text: "A script arrived after the marking of 2 exams was approved.", href: "/admin/marking" },
      { id: "checking-stuck", tone: "red", text: "3 scripts wait for a second marker and nobody can take them.", href: "/admin/marking" },
      { id: "checking-with-lead", tone: "amber", text: "4 scripts wait for the lead marker.", href: "/marking/review" },
      { id: "checking-paused", tone: "amber", text: "5 markers are paused.", href: "/marking/review?tab=markers" },
      { id: "checking-ready", tone: "amber", text: "6 exams are ready for their marking to be approved.", href: "/admin/marking" },
    ]);
  });

  it("uses the singular for one", () => {
    expect(checkingAlerts({ ...NONE, approvedStale: 1, stuckSecond: 1, withLead: 1, markersPaused: 1, readyToApprove: 1 }).map((a) => a.text)).toEqual([
      "A script arrived after the marking of 1 exam was approved.",
      "1 script waits for a second marker and nobody can take it.",
      "1 script waits for the lead marker.",
      "1 marker is paused.",
      "1 exam is ready for its marking to be approved.",
    ]);
  });
});
