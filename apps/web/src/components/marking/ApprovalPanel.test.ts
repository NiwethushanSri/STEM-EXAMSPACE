import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { Approval } from "@/lib/marking-approval";

vi.mock("next/navigation", () => ({ useRouter: () => ({ refresh: vi.fn() }), usePathname: () => "/admin/marking" }));
vi.mock("@/lib/supabase/client", () => ({ createClient: vi.fn() }));
vi.mock("@/app/admin/marking/[examId]/approval/actions", () => ({ approveMarking: vi.fn(), withdrawApproval: vi.fn() }));

const { ApprovalPanel } = await import("./ApprovalPanel");

const EXAM = "11111111-2222-3333-4444-555555555555";
const base: Approval = {
  approvedAt: null,
  approvedByName: null,
  opened: true,
  canApprove: false,
  stale: false,
  blocks: [
    { code: "with_lead", count: 3, withStaff: 0 },
    { code: "waiting_second", count: 2, withStaff: 0 },
    { code: "scripts_not_checked", count: 1, withStaff: 1 },
  ],
  scripts: { checked: 12, withdrawn: 1, void: 0, other: 6 },
  noScript: 2,
  checks: {
    doubleMarking: false,
    samplePercent: 10,
    tolerancePercent: 10,
    seeds: false,
    seedEvery: 10,
    practice: false,
    off: { reason: "Only one marker this term.", byName: "Agatha Approver", at: "2026-11-20T09:00:00+00:00" },
  },
  leadName: "Ermengarde Leadbetter",
  figures: {
    pieces: 18,
    secondMarked: 0,
    withinTolerance: 0,
    settled: { firstStands: 0, secondStands: 0, leadMarks: 0 },
    settledByAParty: 0,
    acceptedAfterPause: 0,
    sentBack: 0,
    finalMarksChanged: 0,
    standards: { practice: 0, seed: 0 },
    seedAttempts: 0,
    seedOutside: 0,
    sampleReviewsOpen: 0,
  },
};
const html = (a: Approval) => renderToStaticMarkup(createElement(ApprovalPanel, { examId: EXAM, approval: a }));
/** The page's text, without tags, entities decoded as far as the words below need. */
const text = (a: Approval) => html(a).replace(/<[^>]+>/g, " ").replace(/&#x27;|&#39;/g, "'").replace(/\s+/g, " ");

describe("ApprovalPanel", () => {
  it("approval_panel_shows_what_blocks_and_the_checks", () => {
    const t = text(base);
    for (const words of [
      "12 checked",
      "1 withdrawn",
      "0 void",
      "2 candidates have no script",
      "What still blocks approval",
      "3 scripts are with the lead marker.",
      "2 scripts wait for a second marker.",
      "1 script is still with staff.",
      "Double marking: off.",
      "Lead marker: Ermengarde Leadbetter.",
      "Checks turned off",
      "Turned off by Agatha Approver on 20 November 2026: Only one marker this term.",
      "What the checks found",
      "Second-marked: 0 of 18 scripts, 0 within tolerance.",
    ]) {
      expect(t).toContain(words);
    }
    expect(html(base)).toMatch(/<button[^>]*disabled=""[^>]*>Approve this exam(&#x27;|')s marking<\/button>/);
    expect(t).not.toContain("Withdraw approval");
    expect(t).not.toContain("A script arrived or changed after this approval.");
  });
  it("approval_panel_offers_approve_when_nothing_blocks", () => {
    const h = html({ ...base, canApprove: true, blocks: [] });
    expect(h).toMatch(/<button[^>]*>Approve this exam(&#x27;|')s marking<\/button>/);
    expect(h).not.toMatch(/<button[^>]*disabled=""[^>]*>Approve this exam/);
    expect(text({ ...base, canApprove: true, blocks: [] })).toContain("Nothing blocks approval.");
    expect(text({ ...base, opened: false, blocks: [] })).toContain("Marking has not opened for this exam.");
  });
  it("approval_panel_says_no_script_has_arrived", () => {
    const t = text({ ...base, blocks: [{ code: "no_scripts", count: 0, withStaff: 0 }], scripts: { checked: 0, withdrawn: 0, void: 0, other: 0 } });
    expect(t).toContain("What still blocks approval");
    expect(t).toContain("No script has arrived for this exam yet.");
    expect(t).not.toContain("Nothing blocks approval.");
  });
  it("approval_panel_once_approved_and_stale", () => {
    const t = text({ ...base, approvedAt: "2026-12-03T10:15:00+00:00", approvedByName: "Agatha Approver", stale: true });
    expect(t).toContain("Approved by Agatha Approver on");
    expect(t).toContain("(UK time).");
    expect(t).toContain("Withdraw approval");
    expect(t).toContain("A script arrived or changed after this approval. Withdraw the approval to include it.");
    expect(t).not.toContain("Approve this exam's marking");
  });
});
