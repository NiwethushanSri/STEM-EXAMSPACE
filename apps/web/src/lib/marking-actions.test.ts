import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/staff-gate", () => ({ requireStaff: vi.fn(async () => ({})) }));

const rpc = vi.fn();
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ rpc }) }));

import { giveBack, nextScript, noteAlert, releaseAlert, releaseAllAlerts } from "@/app/marking/actions";
import { assignSome, assignUnits, reassignUnits, takeBackUnits } from "@/app/admin/marking/actions";

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
