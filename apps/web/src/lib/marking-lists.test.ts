import { describe, expect, it } from "vitest";
import {
  alertKindText,
  deadlineText,
  holdText,
  parseAlerts,
  parseMyWork,
  parseProgress,
  parseUnits,
  pieceHoldLine,
  pieceStateLabel,
  releaseBlockedText,
  type MyPiece,
} from "./marking-lists";

const at = (iso: string) => new Date(iso);

describe("holdText", () => {
  it("hold_text_cases: a Next script hold in 20 minutes, an assigned piece, an ended hold", () => {
    const now = at("2026-12-01T14:15:00Z");
    expect(holdText("2026-12-01T14:35:00Z", now)).toBe("Held for you until 14:35");
    expect(holdText(null, now)).toBe("Assigned to you");
    expect(holdText("2026-12-01T14:14:59Z", now)).toBe("Hold ended");
  });
  it("reads the hold in UK time: summer time is an hour ahead", () => {
    expect(holdText("2027-06-01T13:35:00Z", at("2027-06-01T13:15:00Z"))).toBe("Held for you until 14:35");
  });
  it("still holds at the very minute it ends, as the database does", () => {
    expect(holdText("2026-12-01T14:35:00Z", at("2026-12-01T14:35:00Z"))).toBe("Held for you until 14:35");
  });
  it("says the hold ended for a time it cannot read", () => {
    expect(holdText("nope", at("2026-12-01T14:15:00Z"))).toBe("Hold ended");
  });
});

describe("deadlineText", () => {
  it("deadline_text_in_uk_time_across_the_clock_change", () => {
    const before = at("2026-01-01T00:00:00Z");
    expect(deadlineText("2026-12-12T17:00:00Z", before).text).toBe("Mark by 12 December, 17:00");
    expect(deadlineText("2027-06-12T16:00:00Z", before).text).toBe("Mark by 12 June, 17:00");
    // The clocks go forward at 01:00 UTC on 28 March 2027.
    expect(deadlineText("2027-03-28T00:30:00Z", before).text).toBe("Mark by 28 March, 00:30");
    expect(deadlineText("2027-03-28T01:30:00Z", before).text).toBe("Mark by 28 March, 02:30");
    // The clocks go back at 01:00 UTC on 25 October 2026: 01:30 happens twice.
    expect(deadlineText("2026-10-25T00:30:00Z", before).text).toBe("Mark by 25 October, 01:30");
    expect(deadlineText("2026-10-25T01:30:00Z", before).text).toBe("Mark by 25 October, 01:30");
    expect(deadlineText("2026-10-24T23:30:00Z", before).text).toBe("Mark by 25 October, 00:30");
  });
  it("overdue_only_after_the_deadline", () => {
    const deadline = "2026-12-12T17:00:00Z";
    expect(deadlineText(deadline, at("2026-12-12T16:59:59Z")).overdue).toBe(false);
    expect(deadlineText(deadline, at("2026-12-12T17:00:00Z")).overdue).toBe(false);
    expect(deadlineText(deadline, at("2026-12-12T17:00:01Z")).overdue).toBe(true);
    expect(deadlineText(null, at("2030-01-01T00:00:00Z"))).toEqual({ text: "No deadline", overdue: false });
  });
});

const piece = (over: Partial<MyPiece>): MyPiece => ({
  unitId: "u1",
  examId: "e1",
  scriptNumber: "S-0001",
  indexNumber: "SE-2026-0001",
  groupLabel: null,
  state: "taken",
  how: "next",
  holdUntil: "2026-12-01T14:35:00Z",
  onHold: false,
  holdReason: null,
  pagesChanged: false,
  lastSavedAt: null,
  ...over,
});

describe("a marker's piece", () => {
  const now = at("2026-12-01T14:15:00Z");
  it("is In progress, Submitted or On hold", () => {
    expect(pieceStateLabel(piece({}))).toBe("In progress");
    expect(pieceStateLabel(piece({ state: "open" }))).toBe("In progress");
    expect(pieceStateLabel(piece({ state: "submitted" }))).toBe("Submitted");
    expect(pieceStateLabel(piece({ state: "submitted", onHold: true }))).toBe("On hold");
  });
  it("has a hold line while it is not submitted", () => {
    expect(pieceHoldLine(piece({}), now)).toBe("Held for you until 14:35");
    expect(pieceHoldLine(piece({ how: "assigned", holdUntil: null }), now)).toBe("Assigned to you");
    // A free piece with the marker's marking in progress: their hold ran out.
    expect(pieceHoldLine(piece({ state: "open", holdUntil: null }), now)).toBe("Hold ended. Press Next script to carry on.");
    expect(pieceHoldLine(piece({ state: "submitted", holdUntil: null }), now)).toBeNull();
    // A hold on a piece that is on hold does not run out.
    expect(pieceHoldLine(piece({ onHold: true, holdUntil: "2026-12-01T13:00:00Z" }), now)).toBe("This script is on hold. The lead marker has been told.");
  });
});

describe("parseMyWork", () => {
  const answer = {
    ok: true,
    approved: true,
    lead_subjects: [3],
    exams: [
      {
        exam_id: "e1",
        title: "Physics mock",
        paper: "Paper 1",
        subject: "Physics",
        mode: "by_question",
        groups: [{ id: "g1", label: "Section A", left: 4 }],
        deadline: "2026-12-12T17:00:00Z",
        overdue: false,
        closed: false,
        left: 4,
        mine: { taken: 1, submitted: 2 },
      },
    ],
    pieces: [
      {
        unit_id: "u1",
        exam_id: "e1",
        script_number: "P1-0007",
        index_number: "SE-2026-0001",
        group_label: "Section A",
        state: "taken",
        how: "next",
        hold_until: "2026-12-01T14:35:00Z",
        on_hold: false,
        hold_reason: null,
        pages_changed: true,
        last_saved_at: null,
        first_name: "Wilhelmina",
      },
    ],
  };
  it("reads the marker's exams and pieces", () => {
    const w = parseMyWork(answer);
    expect(w).not.toBeNull();
    expect(w!.approved).toBe(true);
    expect(w!.leadSubjects).toEqual([3]);
    expect(w!.exams[0]).toMatchObject({ examId: "e1", mode: "by_question", left: 4, groups: [{ id: "g1", label: "Section A", left: 4 }] });
    expect(w!.pieces[0]).toMatchObject({ unitId: "u1", scriptNumber: "P1-0007", indexNumber: "SE-2026-0001", pagesChanged: true, holdUntil: "2026-12-01T14:35:00Z" });
  });
  it("keeps only the fields it knows, so nothing else reaches the page", () => {
    expect(JSON.stringify(parseMyWork(answer))).not.toContain("Wilhelmina");
  });
  it("is null for a refusal or a broken answer", () => {
    expect(parseMyWork({ ok: false, code: "forbidden" })).toBeNull();
    expect(parseMyWork(null)).toBeNull();
    expect(parseMyWork([])).toBeNull();
  });
  it("reads an account that is not approved", () => {
    expect(parseMyWork({ ok: true, approved: false, lead_subjects: [], exams: [], pieces: [] })).toEqual({
      approved: false,
      leadSubjects: [],
      exams: [],
      pieces: [],
    });
  });
});

describe("parseProgress and parseUnits", () => {
  it("reads each exam's counts and markers", () => {
    const p = parseProgress({
      ok: true,
      exams: [
        {
          exam_id: "e1",
          title: "Physics mock",
          paper: "Paper 1",
          subject: "Physics",
          mode: "whole",
          deadline: null,
          overdue: true,
          opened_at: "2026-12-01T09:00:00Z",
          closed_at: null,
          scripts: { waiting: 1, ready_to_mark: 2, marking: 3, marked: 4 },
          units: { open: 5, taken: 6, submitted: 7, on_hold: 8 },
          markers: [{ marker_id: "m1", name: "Ann Marker", taken: 2, submitted: 9, last_saved_at: null }],
          alerts_open: 1,
        },
      ],
    });
    expect(p![0]).toMatchObject({
      examId: "e1",
      overdue: true,
      scripts: { waiting: 1, readyToMark: 2, marking: 3, marked: 4 },
      units: { open: 5, taken: 6, submitted: 7, onHold: 8 },
      markers: [{ markerId: "m1", name: "Ann Marker", taken: 2, submitted: 9 }],
      alertsOpen: 1,
    });
    expect(parseProgress({ ok: false, code: "forbidden" })).toBeNull();
  });
  it("reads each piece of an exam, with the index number and no candidate name", () => {
    const u = parseUnits({
      ok: true,
      units: [
        {
          unit_id: "u1",
          script_number: "P1-0007",
          index_number: "SE-2026-0001",
          source: "home",
          group_label: null,
          state: "taken",
          on_hold: false,
          hold_reason: null,
          marker_id: "m1",
          marker_name: "Ann Marker",
          how: "assigned",
          hold_until: null,
          last_saved_at: null,
          submitted_at: null,
          total: null,
          waiting: "picture_unchecked",
          last_name: "Quarterfield",
        },
      ],
    });
    expect(u![0]).toMatchObject({ unitId: "u1", indexNumber: "SE-2026-0001", markerName: "Ann Marker", how: "assigned", waiting: "picture_unchecked" });
    expect(JSON.stringify(u)).not.toContain("Quarterfield");
  });
});

describe("parseAlerts and their words", () => {
  const alert = {
    id: "a1",
    kind: "picture_changed",
    exam_id: "e1",
    exam_title: "Physics mock",
    script_id: "s1",
    script_number: "P1-0007",
    index_number: "SE-2026-0001",
    page_n: 2,
    unit_id: null,
    created_at: "2026-12-01T10:00:00Z",
    can_release: false,
    release_blocked: "picture_unchecked",
  };
  it("reads why Release is not offered", () => {
    expect(parseAlerts({ ok: true, alerts: [alert] })![0]).toMatchObject({ id: "a1", kind: "picture_changed", canRelease: false, releaseBlocked: "picture_unchecked", pageN: 2 });
    expect(parseAlerts({ ok: true, alerts: [{ ...alert, can_release: true, release_blocked: null }] })![0]).toMatchObject({ canRelease: true, releaseBlocked: null });
    expect(parseAlerts({ ok: true, alerts: [{ ...alert, kind: "something_new" }] })).toEqual([]);
  });
  it("gives each reason one plain sentence", () => {
    expect(releaseBlockedText("picture_unchecked")).toBe("Release waits for a staff check of the new marking picture.");
    expect(releaseBlockedText("picture_missing")).toBe("Release waits until every page has a marking picture.");
    expect(releaseBlockedText("taken_back")).toBe("Release waits until staff hand the script back to the markers.");
    expect(releaseBlockedText("pictures_updating")).toBe("Release waits until the new marking pictures are made.");
    expect(releaseBlockedText("something_new")).toBe("This cannot be released yet.");
  });
  it("says what each kind of alert is about", () => {
    for (const k of ["picture_changed", "picture_missing", "name_visible", "pages_set_aside", "pages_changed"] as const) {
      expect(alertKindText(k)).toMatch(/\.$/);
    }
  });
});
