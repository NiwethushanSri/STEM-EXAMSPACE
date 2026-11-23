import { describe, expect, it } from "vitest";
import {
  checksChanged,
  checksNeedReason,
  checksOffLine,
  checksProblem,
  checksTurnOff,
  dayAndTime,
  homeWindowEnds,
  markingChecks,
  parseChecksView,
  parseMarkingView,
  type ChecksView,
  type MarkingView,
} from "./exam-marking";

const answer = {
  ok: true,
  mode: "by_question",
  deadline: "2026-12-10T17:00:00+00:00",
  opened_at: null,
  closed_at: null,
  structure: { version: 4, leaves: 3, max_total: 60.0, ungrouped: 0 },
  markers: 2,
  scripts: { verified: 12, ready_to_mark: 0, marking: 0, marked: 0 },
  waiting: { home_window_open: 4, centre_pages_unsettled: 2, pictures_updating: 0, late_undecided: 0, taken_back: 0, picture_unchecked: 0 },
};

describe("parseMarkingView", () => {
  it("reads marking_exam_get's answer", () => {
    const v = parseMarkingView(answer);
    expect(v).toEqual({
      mode: "by_question",
      deadline: "2026-12-10T17:00:00+00:00",
      openedAt: null,
      closedAt: null,
      structure: { version: 4, leaves: 3, maxTotal: 60, ungrouped: 0 },
      markers: 2,
      scripts: { verified: 12, readyToMark: 0, marking: 0, marked: 0 },
      waiting: { homeWindowOpen: 4, centrePagesUnsettled: 2, picturesUpdating: 0, lateUndecided: 0, takenBack: 0, pictureUnchecked: 0 },
    });
  });
  it("reads the scripts whose marking pictures wait for a staff check (Phase 3A Task 8)", () => {
    expect(parseMarkingView({ ...answer, waiting: { ...answer.waiting, picture_unchecked: 3 } })?.waiting.pictureUnchecked).toBe(3);
    const older = { home_window_open: 0, centre_pages_unsettled: 0, pictures_updating: 0, late_undecided: 0, taken_back: 0 };
    expect(parseMarkingView({ ...answer, waiting: older })?.waiting.pictureUnchecked).toBe(0);
  });
  it("refuses a failed or odd answer", () => {
    expect(parseMarkingView({ ok: false, code: "forbidden" })).toBeNull();
    expect(parseMarkingView(null)).toBeNull();
    expect(parseMarkingView([answer])).toBeNull();
  });
});

describe("home hand-in time", () => {
  it("ends 24 hours after the finish", () => {
    expect(homeWindowEnds("2026-12-02T11:00:00Z", 90)).toBe("2026-12-03T12:30:00.000Z");
  });
  it("reads as a UK day and time", () => {
    expect(dayAndTime("2026-12-03T12:30:00.000Z")).toBe("3 December, 12:30");
    expect(dayAndTime("2027-06-03T11:30:00.000Z")).toBe("3 June, 12:30");
  });
});

describe("markingChecks", () => {
  const v = parseMarkingView(answer) as MarkingView;
  it("says the checks in plain words", () => {
    expect(markingChecks(v, "2026-12-03T12:30:00.000Z")).toEqual([
      "3 questions, 60 marks",
      "2 markers approved",
      "12 scripts verified",
      "4 home scripts wait until 3 December, 12:30",
      "2 centre scripts wait for pages in the queue",
    ]);
  });
  it("names what stops opening and, once open, the progress", () => {
    const open: MarkingView = {
      ...v,
      openedAt: "2026-12-04T09:00:00Z",
      structure: { version: 1, leaves: 1, maxTotal: 7.5, ungrouped: 1 },
      markers: 1,
      scripts: { verified: 1, readyToMark: 5, marking: 2, marked: 3 },
      waiting: { homeWindowOpen: 0, centrePagesUnsettled: 1, picturesUpdating: 1, lateUndecided: 2, takenBack: 1, pictureUnchecked: 1 },
    };
    expect(markingChecks(open, "2026-12-03T12:30:00.000Z")).toEqual([
      "1 question, 7.5 marks",
      "1 question is not in a group",
      "1 marker approved",
      "1 script verified",
      "5 ready to mark, 2 being marked, 3 marked",
      "1 centre script waits for pages in the queue",
      "1 script waits while its pictures are updated",
      "1 script's marking pictures wait for a staff check",
      "2 late scripts wait for a decision",
      "1 script was taken back from marking",
    ]);
    expect(markingChecks({ ...open, waiting: { ...open.waiting, pictureUnchecked: 4 } }, "2026-12-03T12:30:00.000Z")).toContain(
      "4 scripts' marking pictures wait for a staff check",
    );
  });
  it("says when there are no questions or markers", () => {
    const empty: MarkingView = { ...v, mode: "whole", structure: { version: 0, leaves: 0, maxTotal: 0, ungrouped: 2 }, markers: 0 };
    expect(markingChecks(empty, "2026-12-03T12:30:00.000Z").slice(0, 2)).toEqual(["No questions yet", "No markers approved for this subject"]);
  });
});

const checksAnswer = {
  ok: true,
  double_marking: false,
  sample_percent: 20,
  tolerance_percent: 10,
  seeds: true,
  seed_every: 12,
  practice: false,
  off: { reason: "Only one marker for this subject", by_name: "Ada Checker", at: "2026-12-03T00:30:00+00:00" },
  markers_approved: 1,
  can_switch_off: true,
  opened: false,
  approved: false,
};

describe("parseChecksView", () => {
  it("reads the answer of marking_checks_get", () => {
    expect(parseChecksView(checksAnswer)).toEqual({
      doubleMarking: false,
      samplePercent: 20,
      tolerancePercent: 10,
      seeds: true,
      seedEvery: 12,
      practice: false,
      off: { reason: "Only one marker for this subject", byName: "Ada Checker", at: "2026-12-03T00:30:00+00:00" },
      markersApproved: 1,
      canSwitchOff: true,
      opened: false,
      approved: false,
    });
  });
  it("reads nothing turned off, and a name nobody gave", () => {
    expect(parseChecksView({ ...checksAnswer, off: null })?.off).toBeNull();
    expect(parseChecksView({ ...checksAnswer, off: { ...checksAnswer.off, by_name: null } })?.off?.byName).toBeNull();
  });
  it("refuses a failed or odd answer", () => {
    expect(parseChecksView({ ok: false, code: "forbidden" })).toBeNull();
    expect(parseChecksView({ ...checksAnswer, sample_percent: 0 })).toBeNull();
    expect(parseChecksView({ ...checksAnswer, seed_every: "10" })).toBeNull();
    expect(parseChecksView(null)).toBeNull();
  });
});

describe("the rules for saving the checks", () => {
  const saved = parseChecksView({ ...checksAnswer, double_marking: true, seeds: true, practice: true, off: null }) as ChecksView;
  it("checks each number is whole and in range", () => {
    expect(checksProblem(saved)).toBeNull();
    expect(checksProblem({ ...saved, samplePercent: 1 })).toBeNull();
    expect(checksProblem({ ...saved, samplePercent: 101 })).toBe("Second-mark a whole number from 1 to 100% of scripts.");
    expect(checksProblem({ ...saved, samplePercent: 12.5 })).toBe("Second-mark a whole number from 1 to 100% of scripts.");
    expect(checksProblem({ ...saved, tolerancePercent: 0 })).toBe("The difference that goes to the lead marker is a whole number from 1 to 50%.");
    expect(checksProblem({ ...saved, tolerancePercent: 50 })).toBeNull();
    expect(checksProblem({ ...saved, seedEvery: 2 })).toBe("Seeded scripts come about one in every 3 to 50 scripts.");
    expect(checksProblem({ ...saved, seedEvery: Number.NaN })).toBe("Seeded scripts come about one in every 3 to 50 scripts.");
  });
  it("asks for a reason to turn a check off", () => {
    expect(checksTurnOff(saved, { ...saved, seeds: false })).toBe(true);
    expect(checksNeedReason(saved, { ...saved, practice: false })).toBe(true);
    expect(checksNeedReason(saved, { ...saved, samplePercent: 30 })).toBe(false);
    const off = { ...saved, doubleMarking: false };
    expect(checksTurnOff(off, { ...off, doubleMarking: true })).toBe(false);
    expect(checksNeedReason(off, { ...off, doubleMarking: true })).toBe(false);
  });
  it("asks for a reason for any change once marking has opened, and none for no change", () => {
    const opened = { ...saved, opened: true };
    expect(checksNeedReason(opened, { ...opened, seedEvery: 11 })).toBe(true);
    expect(checksChanged(opened, { ...opened })).toBe(false);
    expect(checksNeedReason(opened, { ...opened })).toBe(false);
  });
  it("says who turned the checks off, when (UK date) and why", () => {
    expect(checksOffLine({ reason: "Only one marker", byName: "Ada Checker", at: "2026-12-03T00:30:00+00:00" })).toBe(
      "Turned off by Ada Checker on 3 December 2026: Only one marker",
    );
    expect(checksOffLine({ reason: "Only one marker", byName: null, at: "2026-06-30T23:30:00Z" })).toBe(
      "Turned off by a member of staff on 1 July 2026: Only one marker",
    );
  });
});
