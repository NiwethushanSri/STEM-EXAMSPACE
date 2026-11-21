import { describe, expect, it } from "vitest";
import { dayAndTime, homeWindowEnds, markingChecks, parseMarkingView, type MarkingView } from "./exam-marking";

const answer = {
  ok: true,
  mode: "by_question",
  deadline: "2026-12-10T17:00:00+00:00",
  opened_at: null,
  closed_at: null,
  structure: { version: 4, leaves: 3, max_total: 60.0, ungrouped: 0 },
  markers: 2,
  scripts: { verified: 12, ready_to_mark: 0, marking: 0, marked: 0 },
  waiting: { home_window_open: 4, centre_pages_unsettled: 2, pictures_updating: 0, late_undecided: 0, taken_back: 0 },
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
      waiting: { homeWindowOpen: 4, centrePagesUnsettled: 2, picturesUpdating: 0, lateUndecided: 0, takenBack: 0 },
    });
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
      waiting: { homeWindowOpen: 0, centrePagesUnsettled: 1, picturesUpdating: 1, lateUndecided: 2, takenBack: 1 },
    };
    expect(markingChecks(open, "2026-12-03T12:30:00.000Z")).toEqual([
      "1 question, 7.5 marks",
      "1 question is not in a group",
      "1 marker approved",
      "1 script verified",
      "5 ready to mark, 2 being marked, 3 marked",
      "1 centre script waits for pages in the queue",
      "1 script waits while its pictures are updated",
      "2 late scripts wait for a decision",
      "1 script was taken back from marking",
    ]);
  });
  it("says when there are no questions or markers", () => {
    const empty: MarkingView = { ...v, mode: "whole", structure: { version: 0, leaves: 0, maxTotal: 0, ungrouped: 2 }, markers: 0 };
    expect(markingChecks(empty, "2026-12-03T12:30:00.000Z").slice(0, 2)).toEqual(["No questions yet", "No markers approved for this subject"]);
  });
});
