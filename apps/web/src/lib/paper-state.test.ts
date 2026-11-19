import { describe, expect, it } from "vitest";
import { clockSkewMs, downloadedLine, MAX_WAIT_MS, nextCheckMs, paperMessage, RECHECK_MS, type BookingPaperState } from "./paper-state";

const base: BookingPaperState = {
  sitting: "home",
  status: "open",
  release_at: "2027-06-05T08:50:00Z", // 09:50 in London (BST)
  last_download: null,
  corrected: false,
  inserts: [],
};
const NOW = new Date("2027-06-05T07:00:00Z");
const msg = (o: Partial<BookingPaperState>, now = NOW) => paperMessage({ ...base, ...o }, now);

describe("paperMessage", () => {
  it("centre: handed out in the exam room", () => {
    expect(msg({ status: "centre", sitting: "centre" })).toEqual({
      text: "Your booking is for the centre; your paper is handed out in the exam room",
      action: "none",
    });
  });
  it("missing: the institution has been told", () => {
    expect(msg({ status: "missing" })).toEqual({ text: "Your paper is not ready yet. The institution has been told.", action: "none" });
  });
  it("not_yet: timed text in summer time", () => {
    expect(msg({ status: "not_yet" })).toEqual({ text: "Your paper will be ready at 09:50 on Saturday 5 June", action: "none" });
  });
  it("not_yet: timed text in winter time", () => {
    expect(msg({ status: "not_yet", release_at: "2026-12-05T09:50:00Z" }).text).toBe("Your paper will be ready at 09:50 on Saturday 5 December");
  });
  it("held: paused by the institution", () => {
    expect(msg({ status: "held" })).toEqual({ text: "The paper is paused by the institution. Please wait.", action: "none" });
  });
  it("open: can be downloaded", () => {
    expect(msg({ status: "open" }).action).toBe("download");
  });
  it("closed: nothing to download", () => {
    const m = msg({ status: "closed" });
    expect(m.action).toBe("none");
    expect(m.text).not.toBe("");
  });
  it("booking_paper_state_reports_corrected: asks for a new download", () => {
    expect(msg({ corrected: true, last_download: { at: "2027-06-05T08:51:00Z", by_name: "Pat Tester" } })).toEqual({
      text: "A corrected paper is available. Download it again.",
      action: "download",
    });
  });
});

describe("downloadedLine", () => {
  it("downloaded_line_names_the_person", () => {
    expect(downloadedLine({ at: "2027-06-05T08:52:00Z", by_name: "Pat Tester" }, NOW)).toBe("Downloaded at 09:52 by Pat Tester");
  });
  it("adds the day when it was not today", () => {
    expect(downloadedLine({ at: "2027-06-04T08:52:00Z", by_name: "Pat Tester" }, NOW)).toBe("Downloaded at 09:52 on Friday 4 June by Pat Tester");
  });
  it("works without a name", () => {
    expect(downloadedLine({ at: "2027-06-05T08:52:00Z", by_name: null }, NOW)).toBe("Downloaded at 09:52");
  });
  it("is empty with no download", () => expect(downloadedLine(null, NOW)).toBe(""));
});

describe("nextCheckMs (the family page looks again without a reload)", () => {
  const release = Date.parse(base.release_at!);
  const at = (o: Partial<BookingPaperState>, msBeforeRelease: number, skew = 0) =>
    nextCheckMs({ ...base, ...o }, release - msBeforeRelease, skew);
  it("long before the release: wakes when the last 15 minutes start, never longer than 10 minutes", () => {
    expect(at({ status: "not_yet" }, 20 * 60_000)).toBe(5 * 60_000 + 1000);
    expect(at({ status: "not_yet" }, 3 * 3600_000)).toBe(MAX_WAIT_MS);
  });
  it("within 15 minutes: every 25 s, and once just after the release", () => {
    expect(at({ status: "not_yet" }, 14 * 60_000)).toBe(RECHECK_MS);
    expect(at({ status: "not_yet" }, 10_000)).toBe(11_500);
    expect(at({ status: "not_yet" }, 100)).toBe(1_600);
  });
  it("a not-yet answer after the release (by the server clock) asks again soon, then every 25 s", () => {
    expect(at({ status: "not_yet" }, -2_000)).toBe(5_000);
    expect(at({ status: "not_yet" }, -5 * 60_000)).toBe(RECHECK_MS);
  });
  it("uses the server clock, not the device clock: a device 5 minutes fast does not stop looking", () => {
    // The device thinks the release has passed; the server is 5 minutes behind it, so it is 4 minutes away.
    expect(nextCheckMs({ ...base, status: "not_yet" }, release + 60_000, -5 * 60_000)).toBe(RECHECK_MS);
    // A slow device wakes on the server's release, not its own.
    expect(nextCheckMs({ ...base, status: "not_yet" }, release - 20_000, 15_000)).toBe(6_500);
  });
  it("held and missing keep looking, so a resume or a late upload shows", () => {
    expect(at({ status: "held" }, -60_000)).toBe(RECHECK_MS);
    expect(at({ status: "missing" }, -60_000)).toBe(RECHECK_MS);
  });
  it("open, closed and centre do not look again", () => {
    expect(at({ status: "open" }, 0)).toBeNull();
    expect(at({ status: "closed" }, 0)).toBeNull();
    expect(at({ status: "centre", sitting: "centre" }, 0)).toBeNull();
  });
  it("a missing release time still looks again", () => {
    expect(at({ status: "not_yet", release_at: null }, 0)).toBe(RECHECK_MS);
  });
});

describe("clockSkewMs", () => {
  it("compares the server time with the middle of the request", () => {
    const s = { ...base, server_now: "2027-06-05T08:00:10Z" };
    const t = Date.parse("2027-06-05T08:00:00Z");
    expect(clockSkewMs(s, t - 1000, t + 1000)).toBe(10_000);
  });
  it("is 0 when the server sent no time", () => {
    expect(clockSkewMs(base, 0, 100)).toBe(0);
    expect(clockSkewMs({ ...base, server_now: "nonsense" }, 0, 100)).toBe(0);
  });
});
