import { describe, expect, it } from "vitest";
import { downloadedLine, paperMessage, type BookingPaperState } from "./paper-state";

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
