/** Approving an exam's marking (marking_approval_get), for the admin's approval page: what it reads, and the words it
 * uses. The parser keeps only the fields it knows, so nothing else reaches the page: counts, and the names of staff and
 * the lead marker, never a candidate's. The database checks every rule again (marking_approve,
 * marking_approval_withdraw). */

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const count = (v: unknown): number => (typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : 0);
const text = (v: unknown): string | null => (typeof v === "string" && v.trim() !== "" ? v : null);
const time = (v: unknown): string | null => (typeof v === "string" && !Number.isNaN(Date.parse(v)) ? v : null);

/** What still blocks approval, in the order the database gives them. no_scripts: no script has arrived (its count is
 * 0). */
export const BLOCK_CODES = [
  "no_scripts",
  "scripts_not_checked",
  "with_lead",
  "waiting_second",
  "on_hold",
  "alerts_open",
  "pictures_to_check",
  "pause_pending",
] as const;
export type BlockCode = (typeof BLOCK_CODES)[number];
const isBlock = (v: unknown): v is BlockCode => BLOCK_CODES.includes(v as BlockCode);

/** One block: how many, and (scripts_not_checked only) how many of them are still with staff. */
export type ApprovalBlock = { code: BlockCode; count: number; withStaff: number };

export type ApprovalChecks = {
  doubleMarking: boolean;
  samplePercent: number;
  tolerancePercent: number;
  seeds: boolean;
  seedEvery: number;
  practice: boolean;
  /** Who turned the checks off, when and why; null when nothing is turned off. */
  off: { reason: string | null; byName: string | null; at: string } | null;
};

export type ApprovalFigures = {
  pieces: number;
  secondMarked: number;
  withinTolerance: number;
  settled: { firstStands: number; secondStands: number; leadMarks: number };
  settledByAParty: number;
  acceptedAfterPause: number;
  sentBack: number;
  finalMarksChanged: number;
  standards: { practice: number; seed: number };
  seedAttempts: number;
  seedOutside: number;
  sampleReviewsOpen: number;
};

export type Approval = {
  approvedAt: string | null;
  approvedByName: string | null;
  opened: boolean;
  canApprove: boolean;
  /** Approved, and a script is not checked: one arrived after the approval. */
  stale: boolean;
  blocks: ApprovalBlock[];
  scripts: { checked: number; withdrawn: number; void: number; other: number };
  noScript: number;
  checks: ApprovalChecks;
  leadName: string | null;
  figures: ApprovalFigures;
};

/** marking_approval_get's answer, or the code it was refused with; null for an answer it cannot read. A block this page
 * does not know is left out, and so is one with nothing to count, except no_scripts (whose count is 0). */
export function parseApproval(data: unknown): { ok: true; approval: Approval } | { ok: false; code: string } | null {
  const d = obj(data);
  if (!d) return null;
  if (d.ok !== true) return { ok: false, code: typeof d.code === "string" ? d.code : "internal" };
  const checks = obj(d.checks);
  const figures = obj(d.figures);
  if (!Array.isArray(d.blocks) || !checks || !figures) return null;
  const scripts = obj(d.scripts);
  const off = obj(checks.off);
  const offAt = off ? time(off.at) : null;
  const settled = obj(figures.settled);
  const standards = obj(figures.standards);
  return {
    ok: true,
    approval: {
      approvedAt: time(d.approved_at),
      approvedByName: text(d.approved_by_name),
      opened: d.opened === true,
      canApprove: d.can_approve === true,
      stale: d.stale === true,
      blocks: d.blocks.flatMap((v): ApprovalBlock[] => {
        const b = obj(v);
        return b && isBlock(b.code) && (count(b.count) > 0 || b.code === "no_scripts")
          ? [{ code: b.code, count: count(b.count), withStaff: count(b.with_staff) }]
          : [];
      }),
      scripts: { checked: count(scripts?.checked), withdrawn: count(scripts?.withdrawn), void: count(scripts?.void), other: count(scripts?.other) },
      noScript: count(d.no_script),
      checks: {
        doubleMarking: checks.double_marking === true,
        samplePercent: count(checks.sample_percent),
        tolerancePercent: count(checks.tolerance_percent),
        seeds: checks.seeds === true,
        seedEvery: count(checks.seed_every),
        practice: checks.practice === true,
        off: off && offAt ? { reason: text(off.reason), byName: text(off.by_name), at: offAt } : null,
      },
      leadName: text(d.lead_name),
      figures: {
        pieces: count(figures.pieces),
        secondMarked: count(figures.second_marked),
        withinTolerance: count(figures.within_tolerance),
        settled: { firstStands: count(settled?.first_stands), secondStands: count(settled?.second_stands), leadMarks: count(settled?.lead_marks) },
        settledByAParty: count(figures.settled_by_a_party),
        acceptedAfterPause: count(figures.accepted_after_pause),
        sentBack: count(figures.sent_back),
        finalMarksChanged: count(figures.final_marks_changed),
        standards: { practice: count(standards?.practice), seed: count(standards?.seed) },
        seedAttempts: count(figures.seed_attempts),
        seedOutside: count(figures.seed_outside),
        sampleReviewsOpen: count(figures.sample_reviews_open),
      },
    },
  };
}

/** "1 script", "3 scripts". */
const scripts = (n: number) => `${n} ${n === 1 ? "script" : "scripts"}`;
/** "1 script is", "3 scripts are". */
const scriptsAre = (n: number) => `${scripts(n)} ${n === 1 ? "is" : "are"}`;

/** One plain sentence for what blocks approval: "No script has arrived for this exam yet.", "3 scripts are with the
 * lead marker.", "2 scripts wait for a second marker.", "1 script is still with staff."; "" for a block this page does
 * not know. */
export function blockText(b: ApprovalBlock): string {
  const n = b.count;
  switch (b.code) {
    case "no_scripts":
      return "No script has arrived for this exam yet.";
    case "scripts_not_checked":
      if (b.withStaff >= n) return `${scriptsAre(n)} still with staff.`;
      if (b.withStaff === 0) return `${scriptsAre(n)} not checked yet.`;
      return `${scriptsAre(n)} not checked yet, ${b.withStaff} of them still with staff.`;
    case "with_lead":
      return `${scriptsAre(n)} with the lead marker.`;
    case "waiting_second":
      return `${scripts(n)} ${n === 1 ? "waits" : "wait"} for a second marker.`;
    case "on_hold":
      return `${scriptsAre(n)} on hold.`;
    case "alerts_open":
      return `${n} ${n === 1 ? "alert needs" : "alerts need"} attention.`;
    case "pictures_to_check":
      return `${scripts(n)} ${n === 1 ? "has a marking picture" : "have marking pictures"} for staff to check.`;
    case "pause_pending":
      return `${n} paused ${n === 1 ? "marker's" : "markers'"} scripts have not gone to the lead marker yet. This clears within a minute.`;
    default:
      return "";
  }
}

/** The "Scripts" lines: "12 checked", "1 withdrawn", "0 void", "2 candidates have no script". */
export function scriptLines(a: Pick<Approval, "scripts" | "noScript">): string[] {
  return [
    `${a.scripts.checked} checked`,
    `${a.scripts.withdrawn} withdrawn`,
    `${a.scripts.void} void`,
    `${a.noScript} ${a.noScript === 1 ? "candidate has" : "candidates have"} no script`,
  ];
}

/** The checks in words, one line each, in the words of the checks' settings. */
export function checkLines(c: ApprovalChecks): string[] {
  return [
    c.doubleMarking
      ? `Double marking: second-mark ${c.samplePercent}% of scripts, and send to the lead marker when marks differ by more than ${c.tolerancePercent}% of the maximum.`
      : "Double marking: off.",
    c.seeds ? `Seeded scripts: about one in every ${c.seedEvery} scripts.` : "Seeded scripts: off.",
    c.practice ? "Practice before live marking: on." : "Practice before live marking: off.",
  ];
}

/** "What the checks found", one line each. */
export function figureLines(f: ApprovalFigures): string[] {
  const settled = f.settled.firstStands + f.settled.secondStands + f.settled.leadMarks;
  const lines = [
    `Second-marked: ${f.secondMarked} of ${scripts(f.pieces)}, ${f.withinTolerance} within tolerance.`,
    settled === 0
      ? "Differences settled: none."
      : `Differences settled: ${settled} (First marks stand ${f.settled.firstStands}, Second marks stand ${f.settled.secondStands}, the lead marker's own marks ${f.settled.leadMarks}).`,
  ];
  if (settled > 0) lines.push(`Settled by a lead marker who was one of the two markers: ${f.settledByAParty}.`);
  lines.push(
    `Accepted after a marker was paused: ${f.acceptedAfterPause}.`,
    `Sent back: ${f.sentBack}.`,
    `Final marks changed by the lead marker: ${scripts(f.finalMarksChanged)}.`,
    f.standards.seed === 0
      ? "Seeded scripts: none."
      : `Seeded scripts: ${f.standards.seed}, with ${f.seedAttempts} ${f.seedAttempts === 1 ? "attempt" : "attempts"}, ${f.seedOutside} outside tolerance.`,
    `Practice scripts: ${f.standards.practice}.`,
  );
  if (f.sampleReviewsOpen > 0) lines.push(`Routine samples still open: ${f.sampleReviewsOpen}. They do not block approval.`);
  return lines;
}

/** Shown while an approval is stale (Ruling R22): it is approved and something blocks it, as a script that arrived, or a
 * name reported, a picture changed or an alert raised on a script since. */
export const STALE_TEXT = "A script arrived or changed after this approval. Withdraw the approval to include it.";

/** Why an approval note cannot be sent (null: it can): optional; given, 3 to 300 characters (Ruling R22). */
export function noteProblem(note: string): string | null {
  const n = note.trim().length;
  return n > 0 && (n < 3 || n > 300) ? "A note can be 3 to 300 characters, or leave it empty." : null;
}
