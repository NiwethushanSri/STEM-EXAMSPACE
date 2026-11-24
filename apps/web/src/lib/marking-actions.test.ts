import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/staff-gate", () => ({ requireStaff: vi.fn(async () => ({})) }));

const rpc = vi.fn();
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ rpc }) }));

import { giveBack, nextScript, noteAlert, releaseAlert, releaseAllAlerts } from "@/app/marking/actions";
import { addSecond, assignSecond, assignSome, assignUnits, dropSecond, reassignUnits, takeBackSecond, takeBackUnits } from "@/app/admin/marking/actions";
import {
  acceptReview,
  clearMarker,
  pauseMarker,
  retireStandard,
  sampleMarker,
  sendBack,
  setFinalMarks,
  setStandard,
  settleReview,
} from "@/app/marking/review/actions";

const EXAM = "11111111-1111-4111-8111-111111111111";
const GROUP = "22222222-2222-4222-8222-222222222222";
const UNIT = "33333333-3333-4333-8333-333333333333";
const MARKER = "44444444-4444-4444-8444-444444444444";
const ALERT = "55555555-5555-4555-8555-555555555555";
const answer = (data: unknown) => rpc.mockResolvedValue({ data, error: null });

beforeEach(() => rpc.mockReset());

describe("a marker's actions", () => {
  it("Next script hands back the piece to open", async () => {
    answer({ ok: true, unit_id: UNIT, resumed: false });
    expect(await nextScript(EXAM)).toEqual({ ok: true, unitId: UNIT });
    expect(rpc).toHaveBeenCalledWith("marking_next", { p_exam: EXAM, p_group: null });
    await nextScript(EXAM, GROUP);
    expect(rpc).toHaveBeenLastCalledWith("marking_next", { p_exam: EXAM, p_group: GROUP });
  });
  it("Next script says when nothing is left", async () => {
    answer({ ok: false, code: "nothing_left" });
    expect(await nextScript(EXAM)).toEqual({ ok: false, message: "Nothing left to mark for now." });
  });
  it("refuses ids that are not ones before calling the database", async () => {
    expect((await nextScript("nope")).ok).toBe(false);
    expect((await nextScript(EXAM, "nope")).ok).toBe(false);
    expect((await giveBack("nope")).ok).toBe(false);
    expect(rpc).not.toHaveBeenCalled();
  });
  it("gives a piece back with or without a reason", async () => {
    answer({ ok: true });
    expect((await giveBack(UNIT)).ok).toBe(true);
    expect(rpc).toHaveBeenLastCalledWith("marking_give_back", { p_unit: UNIT, p_reason: null });
    await giveBack(UNIT, "  Not my subject  ");
    expect(rpc).toHaveBeenLastCalledWith("marking_give_back", { p_unit: UNIT, p_reason: "Not my subject" });
    expect(await giveBack(UNIT, "no")).toEqual({ ok: false, message: "Give a reason of 3 to 300 characters." });
    expect(rpc).toHaveBeenCalledTimes(2);
  });
  it("a database error is the generic message", async () => {
    rpc.mockResolvedValue({ data: null, error: { message: "boom" } });
    expect(await giveBack(UNIT)).toEqual({ ok: false, message: "Something went wrong. Please try again." });
  });
});

describe("the lead's and admins' alert actions", () => {
  it("ask for a reason first", async () => {
    expect(await releaseAlert(ALERT, " ")).toEqual({ ok: false, message: "Give a reason of 3 to 300 characters." });
    expect(await noteAlert(ALERT, "")).toEqual({ ok: false, message: "Give a reason of 3 to 300 characters." });
    expect(await releaseAllAlerts(EXAM, "x")).toEqual({ ok: false, message: "Give a reason of 3 to 300 characters." });
    expect(rpc).not.toHaveBeenCalled();
  });
  it("release one alert, or say why it waits", async () => {
    answer({ ok: true, released: 2 });
    expect((await releaseAlert(ALERT, "Pictures checked")).ok).toBe(true);
    expect(rpc).toHaveBeenCalledWith("marking_alert_release", { p_alert: ALERT, p_reason: "Pictures checked" });
    answer({ ok: false, code: "conflict", reason: "picture_unchecked" });
    expect(await releaseAlert(ALERT, "Pictures checked")).toEqual({ ok: false, message: "Release waits for a staff check of the new marking picture." });
  });
  it("note an alert", async () => {
    answer({ ok: true });
    expect((await noteAlert(ALERT, "Seen it")).ok).toBe(true);
    expect(rpc).toHaveBeenCalledWith("marking_alert_note", { p_alert: ALERT, p_reason: "Seen it" });
  });
  it("release every alert of an exam that can be", async () => {
    answer({ ok: true, released: 3, blocked: 1 });
    const r = await releaseAllAlerts(EXAM, "All checked");
    expect(rpc).toHaveBeenCalledWith("marking_alerts_release_all", { p_exam: EXAM, p_reason: "All checked" });
    expect(r).toEqual({ ok: true, message: "3 alerts released. 1 was left because you cannot mark its candidate." });
    answer({ ok: true, released: 0, blocked: 0 });
    expect(await releaseAllAlerts(EXAM, "All checked")).toEqual({ ok: true, message: "No alert could be released yet." });
  });
});

describe("an admin's allocation actions", () => {
  it("assign scripts and say which were skipped and why", async () => {
    answer({ ok: true, assigned: 2, skipped: [{ unit_id: UNIT, code: "taken" }, { unit_id: GROUP, code: "taken" }, { unit_id: EXAM, code: "on_hold" }] });
    const r = await assignUnits([UNIT, GROUP, EXAM], MARKER, "Cover for Ann");
    expect(rpc).toHaveBeenCalledWith("marking_assign", { p_units: [UNIT, GROUP, EXAM], p_marker: MARKER, p_reason: "Cover for Ann" });
    expect(r).toEqual({
      ok: true,
      message: "2 scripts assigned. 2 not assigned: A marker already has this script. Take it back or reassign it. 1 not assigned: This script is on hold.",
    });
  });
  it("assign the next n, of a group when given", async () => {
    answer({ ok: true, assigned: 5 });
    expect(await assignSome(EXAM, null, MARKER, 5, "Even the load")).toEqual({ ok: true, message: "5 scripts assigned." });
    expect(rpc).toHaveBeenCalledWith("marking_assign_some", { p_exam: EXAM, p_group: null, p_marker: MARKER, p_count: 5, p_reason: "Even the load" });
    answer({ ok: true, assigned: 0 });
    expect(await assignSome(EXAM, GROUP, MARKER, 5, "Even the load")).toEqual({ ok: true, message: "No script was free to assign." });
    expect((await assignSome(EXAM, null, MARKER, 0, "Even the load")).ok).toBe(false);
    expect((await assignSome(EXAM, null, MARKER, 201, "Even the load")).ok).toBe(false);
    expect(rpc).toHaveBeenCalledTimes(2);
  });
  it("take back and reassign", async () => {
    answer({ ok: true, taken_back: 1 });
    expect(await takeBackUnits([UNIT], "Marked wrongly")).toEqual({ ok: true, message: "1 script taken back." });
    answer({ ok: true, taken_back: 1, assigned: 1, skipped: [] });
    expect(await reassignUnits([UNIT], MARKER, "Marked wrongly")).toEqual({ ok: true, message: "1 script reassigned." });
    expect(rpc).toHaveBeenLastCalledWith("marking_reassign", { p_units: [UNIT], p_marker: MARKER, p_reason: "Marked wrongly" });
  });
  it("refuse a choice of no scripts, too many, or ids that are not ones", async () => {
    expect((await takeBackUnits([], "Marked wrongly")).ok).toBe(false);
    expect((await takeBackUnits(Array(201).fill(UNIT), "Marked wrongly")).ok).toBe(false);
    expect((await assignUnits([UNIT], "nope", "Cover")).ok).toBe(false);
    expect((await reassignUnits(["nope"], MARKER, "Cover")).ok).toBe(false);
    expect(rpc).not.toHaveBeenCalled();
  });
  it("say why the database refused", async () => {
    answer({ ok: false, code: "not_approved" });
    expect(await assignSome(EXAM, null, MARKER, 3, "Even the load")).toEqual({ ok: false, message: "This marker is not approved to mark this subject." });
  });
});

describe("the lead's review actions", () => {
  const REVIEW = "66666666-6666-4666-8666-666666666666";
  const marks = [{ question_id: GROUP, mark: 2, na: false }];
  it("settle a difference at the revs shown, with the lead's marks only for Set my own marks", async () => {
    answer({ ok: true, check_state: "checked" });
    expect(await settleReview(REVIEW, "first_stands", 3, 2, " Agreed with the first ")).toEqual({ ok: true });
    expect(rpc).toHaveBeenLastCalledWith("marking_review_settle", {
      p_review: REVIEW,
      p_outcome: "first_stands",
      p_first_rev: 3,
      p_second_rev: 2,
      p_reason: "Agreed with the first",
      p_marks: null,
    });
    await settleReview(REVIEW, "lead_marks", 3, 2, "My own view", marks);
    expect(rpc).toHaveBeenLastCalledWith("marking_review_settle", {
      p_review: REVIEW,
      p_outcome: "lead_marks",
      p_first_rev: 3,
      p_second_rev: 2,
      p_reason: "My own view",
      p_marks: marks,
    });
  });
  it("a marking changed since it was shown is refused in plain words", async () => {
    answer({ ok: false, code: "conflict", reason: "changed" });
    expect(await settleReview(REVIEW, "second_stands", 3, 2, "Second is right")).toEqual({
      ok: false,
      message: "A marker changed this script while you were looking. Reload to see it.",
    });
  });
  it("checks the reason, the outcome, the revs, the marks and the note before calling the database", async () => {
    expect(await settleReview(REVIEW, "first_stands", 3, 2, "no")).toEqual({ ok: false, message: "Give a reason of 3 to 300 characters." });
    expect((await settleReview(REVIEW, "both", 3, 2, "Agreed")).ok).toBe(false);
    expect((await settleReview(REVIEW, "first_stands", 1.5, 2, "Agreed")).ok).toBe(false);
    expect((await settleReview(REVIEW, "lead_marks", 3, 2, "My own view")).ok).toBe(false);
    expect((await settleReview(REVIEW, "lead_marks", 3, 2, "My own view", [{ question_id: GROUP, mark: 2, na: true }])).ok).toBe(false);
    expect(await sendBack(UNIT, "same", "no", "Too generous")).toEqual({ ok: false, message: "Write a note of 3 to 1,000 characters." });
    expect((await sendBack(UNIT, "same", "Look at 2(b).", "x")).ok).toBe(false);
    expect((await sendBack(UNIT, "elsewhere", "Look at 2(b).", "Too generous")).ok).toBe(false);
    expect(await acceptReview(REVIEW, "x")).toEqual({ ok: false, message: "Give a reason of 3 to 300 characters." });
    expect(await setStandard(UNIT, "seed", "ok")).toEqual({ ok: false, message: "Write a note of 3 to 1,000 characters." });
    expect((await setFinalMarks(UNIT, [], "Misread 1(a)")).ok).toBe(false);
    expect((await sampleMarker(EXAM, MARKER, 21)).ok).toBe(false);
    expect(rpc).not.toHaveBeenCalled();
  });
  it("accept with or without a reason", async () => {
    answer({ ok: true, check_state: "checked" });
    expect(await acceptReview(REVIEW)).toEqual({ ok: true });
    expect(rpc).toHaveBeenLastCalledWith("marking_review_accept", { p_review: REVIEW, p_reason: null });
    await acceptReview(REVIEW, "Looks right");
    expect(rpc).toHaveBeenLastCalledWith("marking_review_accept", { p_review: REVIEW, p_reason: "Looks right" });
  });
  it("send back, and say when it went to another marker instead", async () => {
    answer({ ok: true, to: "same" });
    expect(await sendBack(UNIT, "same", " Look at 2(b). ", "Too generous")).toEqual({ ok: true, message: "Sent back to the same marker." });
    expect(rpc).toHaveBeenLastCalledWith("marking_send_back", { p_unit: UNIT, p_to: "same", p_note: "Look at 2(b).", p_reason: "Too generous" });
    answer({ ok: true, to: "other" });
    expect(await sendBack(UNIT, "same", "Look at 2(b).", "Too generous")).toEqual({
      ok: true,
      message: "The same marker can no longer mark this script, so another marker will mark it again.",
    });
    expect(await sendBack(UNIT, "other", "Look at 2(b).", "Too generous")).toEqual({ ok: true, message: "Another marker will mark this script again." });
    answer({ ok: false, code: "marking_closed" });
    expect(await sendBack(UNIT, "other", "Look at 2(b).", "Too generous")).toEqual({
      ok: false,
      message: "Marking has closed for this exam, so nobody could mark this script again.",
    });
  });
  it("change a final mark of a checked script", async () => {
    answer({ ok: true, total: 12.5 });
    expect(await setFinalMarks(UNIT, marks, "Misread 1(a)")).toEqual({ ok: true, message: "Final marks changed. The total is now 12.5." });
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(rpc).toHaveBeenLastCalledWith("marking_final_set", { p_unit: UNIT, p_marks: marks, p_reason: "Misread 1(a)" });
  });
  it("change a final mark of a paused marker's script: accepted first, then changed", async () => {
    rpc
      .mockResolvedValueOnce({ data: { ok: true, check_state: "checked" }, error: null })
      .mockResolvedValueOnce({ data: { ok: true, total: 9 }, error: null });
    expect(await setFinalMarks(UNIT, marks, "Misread 1(a)", REVIEW)).toEqual({ ok: true, message: "Final marks changed. The total is now 9." });
    expect(rpc.mock.calls).toEqual([
      ["marking_review_accept", { p_review: REVIEW, p_reason: "Misread 1(a)" }],
      ["marking_final_set", { p_unit: UNIT, p_marks: marks, p_reason: "Misread 1(a)" }],
    ]);
  });
  it("says when the script was accepted but the mark was not changed", async () => {
    rpc
      .mockResolvedValueOnce({ data: { ok: true, check_state: "to_lead" }, error: null })
      .mockResolvedValueOnce({ data: { ok: false, code: "conflict", reason: "with_lead" }, error: null });
    expect(await setFinalMarks(UNIT, marks, "Misread 1(a)", REVIEW)).toEqual({
      ok: false,
      message: "The script was accepted, but the mark was not changed. This script is with the lead marker. Settle or accept it first.",
    });
    rpc.mockReset();
    answer({ ok: false, code: "conflict", reason: "settled" });
    expect(await setFinalMarks(UNIT, marks, "Misread 1(a)", REVIEW)).toEqual({ ok: false, message: "This review is already closed. Refresh the page." });
    expect(rpc).toHaveBeenCalledTimes(1);
  });
  it("the routine sample, clearing, pausing and the standards", async () => {
    answer({ ok: true, added: 5 });
    expect(await sampleMarker(EXAM, MARKER, 5)).toEqual({ ok: true, message: "5 scripts added to your sample." });
    expect(rpc).toHaveBeenLastCalledWith("marking_review_sample", { p_exam: EXAM, p_marker: MARKER, p_count: 5 });
    answer({ ok: true, added: 0 });
    expect(await sampleMarker(EXAM, MARKER, 5)).toEqual({ ok: true, message: "None of their scripts could be added to your sample." });
    answer({ ok: true });
    expect((await clearMarker(EXAM, MARKER, "Practice is good")).ok).toBe(true);
    expect(rpc).toHaveBeenLastCalledWith("marking_marker_clear", { p_exam: EXAM, p_marker: MARKER, p_reason: "Practice is good" });
    expect((await pauseMarker(EXAM, MARKER, "Too many misses")).ok).toBe(true);
    expect(rpc).toHaveBeenLastCalledWith("marking_marker_pause", { p_exam: EXAM, p_marker: MARKER, p_reason: "Too many misses" });
    answer({ ok: true, standard_id: GROUP });
    expect((await setStandard(UNIT, "practice")).ok).toBe(true);
    expect(rpc).toHaveBeenLastCalledWith("marking_standard_set", { p_unit: UNIT, p_use: "practice", p_note: null });
    await setStandard(UNIT, "seed", " Generous on 2. ");
    expect(rpc).toHaveBeenLastCalledWith("marking_standard_set", { p_unit: UNIT, p_use: "seed", p_note: "Generous on 2." });
    answer({ ok: false, code: "conflict", reason: "retired" });
    expect(await retireStandard(GROUP, "No longer fair")).toEqual({ ok: false, message: "This script is no longer used." });
  });
});

describe("an admin's second-marking actions", () => {
  it("second-mark these, and say which were skipped and why", async () => {
    answer({ ok: true, added: 1, skipped: [{ unit_id: GROUP, code: "with_lead" }] });
    expect(await addSecond([UNIT, GROUP], "A second look")).toEqual({
      ok: true,
      message: "1 script will be second-marked. 1 not added: This script is with the lead marker.",
    });
    expect(rpc).toHaveBeenLastCalledWith("marking_second_add", { p_units: [UNIT, GROUP], p_reason: "A second look" });
  });
  it("release from second marking", async () => {
    answer({ ok: true, dropped: 2, skipped: [] });
    expect(await dropSecond([UNIT, GROUP], "Nobody can take them")).toEqual({ ok: true, message: "2 scripts released from second marking." });
    expect(rpc).toHaveBeenLastCalledWith("marking_second_drop", { p_units: [UNIT, GROUP], p_reason: "Nobody can take them" });
  });
  it("assign and take back second marking: the second pass, never the first", async () => {
    answer({ ok: true, assigned: 0, skipped: [{ unit_id: UNIT, code: "not_eligible" }] });
    expect(await assignSecond([UNIT], MARKER, "Cover for Ann")).toEqual({
      ok: true,
      message: "0 scripts assigned for second marking. 1 not assigned: This script cannot be given to this marker.",
    });
    expect(rpc).toHaveBeenLastCalledWith("marking_assign", { p_units: [UNIT], p_marker: MARKER, p_reason: "Cover for Ann", p_kind: "second" });
    answer({ ok: true, taken_back: 1 });
    expect(await takeBackSecond([UNIT], "Marked wrongly")).toEqual({ ok: true, message: "Second marking of 1 script taken back." });
    expect(rpc).toHaveBeenLastCalledWith("marking_take_back", { p_units: [UNIT], p_reason: "Marked wrongly", p_kind: "second" });
  });
  it("refuse a choice of no scripts or no marker", async () => {
    expect((await addSecond([], "A second look")).ok).toBe(false);
    expect((await assignSecond([UNIT], "nope", "Cover")).ok).toBe(false);
    expect((await dropSecond([UNIT], "x")).ok).toBe(false);
    expect(rpc).not.toHaveBeenCalled();
  });
});
