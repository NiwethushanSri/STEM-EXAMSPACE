import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { ProgressExam } from "@/lib/marking-lists";

vi.mock("next/navigation", () => ({ useRouter: () => ({ refresh: vi.fn() }) }));
vi.mock("@/app/marking/actions", () => ({ releaseAllAlerts: vi.fn() }));

const { MarkingProgress } = await import("./MarkingProgress");

const exam: ProgressExam = {
  examId: "11111111-2222-3333-4444-555555555555",
  title: "Physics mock",
  paper: "Paper 1",
  subject: "Physics",
  mode: "whole",
  deadline: null,
  overdue: false,
  openedAt: "2026-12-01T09:00:00Z",
  closedAt: null,
  scripts: { waiting: 0, readyToMark: 4, marking: 1, marked: 17, checked: 12 },
  units: { open: 4, taken: 1, submitted: 17, onHold: 0 },
  checks: { waitingSecond: 2, withLead: 3, stuckSecond: 0, pausedMarkers: 0, approvedAt: null },
  markers: [],
  alertsOpen: 0,
};
const text = (e: ProgressExam) =>
  renderToStaticMarkup(createElement(MarkingProgress, { exams: [e], now: "2026-12-02T12:00:00Z" }))
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ");

describe("MarkingProgress", () => {
  it("progress_card_says_what_the_checks_hold: checked, with the lead marker and waiting for a second marker", () => {
    expect(text(exam)).toContain("12 checked · 3 with the lead marker · 2 waiting for a second marker");
  });

  it("says only what there is, and nothing of the checks before marking opens", () => {
    const quiet = { ...exam, checks: { ...exam.checks, waitingSecond: 0, withLead: 0 } };
    expect(text(quiet)).toContain(" 12 checked ");
    expect(text(quiet)).not.toContain("with the lead marker");
    expect(text(quiet)).not.toContain("waiting for a second marker");
    expect(text({ ...exam, openedAt: null })).not.toContain("checked");
  });
});
