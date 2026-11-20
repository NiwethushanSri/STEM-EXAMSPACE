import { describe, expect, it } from "vitest";
import {
  DEFAULT_ALLOWED_MATERIALS,
  DEFAULT_HOME_RULES,
  PRINT_AT_ACTUAL_SIZE,
  sittingPhaseText,
  sittingSkewMs,
  type SittingState,
} from "./sitting-state";

const T = (s: string) => Date.parse(s);
const state = (over: Partial<SittingState> = {}): SittingState => ({
  phase: "before_start",
  server_now: "2031-06-07T08:00:00.000Z",
  starts_at: "2031-06-07T09:00:00.000Z",
  finish_at: "2031-06-07T10:30:00.000Z",
  on_time_until: "2031-06-07T12:30:00.000Z",
  late_until: "2031-06-08T10:30:00.000Z",
  rules: null,
  materials: null,
  acknowledged: null,
  ack_as: "parent",
  has_parent: true,
  script: null,
  submission: null,
  ...over,
});

describe("sittingPhaseText", () => {
  it("countdown_uses_server_offset", () => {
    // The device clock is 5 minutes behind the database: the state was fetched when the device read 07:55 and the
    // server said 08:00, so the offset is +5 minutes.
    const s = state();
    const skew = sittingSkewMs(s, T("2031-06-07T07:55:00Z"), T("2031-06-07T07:55:00Z"));
    expect(skew).toBe(5 * 60_000);
    // A device reading 07:55 is really 08:00: one hour to the start, not 1 h 05 min.
    expect(sittingPhaseText(s, T("2031-06-07T07:55:00Z"), skew).countdown).toBe("Starts in 1:00:00");
    expect(sittingPhaseText(s, T("2031-06-07T07:55:00Z"), 0).countdown).toBe("Starts in 1:05:00");
    // The midpoint of a slow request is used.
    expect(sittingSkewMs(s, T("2031-06-07T07:54:58Z"), T("2031-06-07T07:55:02Z"))).toBe(5 * 60_000);
    // No server time: no correction.
    expect(sittingSkewMs({ ...s, server_now: "" }, 1000, 2000)).toBe(0);
  });

  it("phase_texts", () => {
    const s = state();
    const at = (iso: string, over: Partial<SittingState> = {}) => sittingPhaseText({ ...s, ...over }, T(iso), 0);
    expect(at("2031-06-07T08:59:59Z")).toEqual({ phase: "before_start", title: "Your exam has not started", countdown: "Starts in 0:00:01" });
    // The page moves on by itself when the time passes, without asking the server.
    expect(at("2031-06-07T09:00:00Z")).toEqual({ phase: "sitting", title: "Your exam is under way", countdown: "1:30:00 left" });
    expect(at("2031-06-07T10:29:59Z").countdown).toBe("0:00:01 left");
    expect(at("2031-06-07T10:30:00Z")).toEqual({
      phase: "upload_open",
      title: "Upload your answers",
      countdown: "2:00:00 left to upload on time",
    });
    expect(at("2031-06-07T12:30:00Z")).toEqual({
      phase: "late_window",
      title: "Upload your answers: now late",
      countdown: "Uploads now are marked late. 22:00:00 left to upload at all",
    });
    expect(at("2031-06-08T10:30:00Z")).toEqual({ phase: "closed", title: "Uploads are closed", countdown: "" });
    // Days are spelled out when far away.
    expect(at("2031-06-04T09:00:00Z").countdown).toBe("Starts in 3 days");
    // A cancelled exam stays closed whatever the time.
    expect(at("2031-06-07T09:30:00Z", { phase: "closed" }).phase).toBe("closed");
  });
});

describe("home sitting texts", () => {
  it("tells families to print at actual size, in the default rules too", () => {
    expect(PRINT_AT_ACTUAL_SIZE).toBe("Print at actual size (100%), not 'Fit to page'.");
    expect(DEFAULT_HOME_RULES).toContain(PRINT_AT_ACTUAL_SIZE);
    expect(DEFAULT_ALLOWED_MATERIALS.length).toBeGreaterThan(0);
    expect(DEFAULT_HOME_RULES.length).toBeLessThanOrEqual(2000);
    expect(DEFAULT_ALLOWED_MATERIALS.length).toBeLessThanOrEqual(500);
  });
});
