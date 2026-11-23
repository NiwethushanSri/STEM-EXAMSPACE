import { describe, expect, it } from "vitest";
import { allocationMessageFor, markingMessageFor, markingScreenMessageFor, standardMessageFor } from "@stem/shared";
import { FEEDBACK_HEADING, feedbackRows, markText, parseFeedback, totalText, type Feedback } from "./marking-feedback";

const U = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

/** marking_feedback's answer for a practice script: question 2(a) NR against the lead's 0 agrees, 3 is out. */
const answer = {
  ok: true,
  use: "practice",
  total: 11,
  lead_total: 15.5,
  max_total: 24,
  note: "Question 3 needs the units for the last mark.",
  questions: [
    { question_id: U(1), label: "1", max: 5, yours: 3, yours_na: false, lead: 3, lead_na: false, out: false },
    { question_id: U(2), label: "2(a)", max: 4, yours: null, yours_na: true, lead: 0, lead_na: false, out: false },
    { question_id: U(3), label: "3", max: 15, yours: 8, yours_na: false, lead: 12.5, lead_na: false, out: true },
  ],
  first_name: "Wilhelmina",
};

describe("parseFeedback", () => {
  it("reads the attempt beside the lead marker's marks and keeps only the fields it knows", () => {
    const r = parseFeedback(answer);
    if (!r.ok) throw new Error("not ok");
    expect(r.feedback).toEqual({
      use: "practice",
      total: 11,
      leadTotal: 15.5,
      maxTotal: 24,
      note: "Question 3 needs the units for the last mark.",
      questions: [
        { questionId: U(1), label: "1", max: 5, yours: 3, yoursNa: false, lead: 3, leadNa: false, out: false },
        { questionId: U(2), label: "2(a)", max: 4, yours: null, yoursNa: true, lead: 0, leadNa: false, out: false },
        { questionId: U(3), label: "3", max: 15, yours: 8, yoursNa: false, lead: 12.5, leadNa: false, out: true },
      ],
    });
    expect(JSON.stringify(r)).not.toContain("Wilhelmina");
  });
  it("reads a missed seeded script, with no note", () => {
    const r = parseFeedback({ ...answer, use: "seed", note: null });
    if (!r.ok) throw new Error("not ok");
    expect([r.feedback.use, r.feedback.note]).toEqual(["seed", null]);
  });
  it("returns the refusal's code, or internal for an answer that makes no sense", () => {
    expect(parseFeedback({ ok: false, code: "forbidden" })).toEqual({ ok: false, code: "forbidden" });
    expect(parseFeedback({ ok: false })).toEqual({ ok: false, code: "internal" });
    expect(parseFeedback(null)).toEqual({ ok: false, code: "internal" });
    expect(parseFeedback({ ...answer, use: "live" })).toEqual({ ok: false, code: "internal" });
  });
});

describe("the marker's feedback", () => {
  it("mark_text_cases: NR, a whole mark, a half mark and none", () => {
    expect(markText(null, true)).toBe("NR");
    expect(markText(3, false)).toBe("3");
    expect(markText(2.5, false)).toBe("2.5");
    expect(markText(null, false)).toBe("–");
    expect(markText(0, false)).toBe("0");
  });

  it("feedback_rows_mark_the_different_questions", () => {
    const r = parseFeedback(answer);
    if (!r.ok) throw new Error("not ok");
    expect(feedbackRows(r.feedback)).toEqual([
      { label: "1", yours: "3", lead: "3", different: false },
      { label: "2(a)", yours: "NR", lead: "0", different: false },
      { label: "3", yours: "8", lead: "12.5", different: true },
    ]);
    const none: Feedback = { ...r.feedback, questions: [] };
    expect(feedbackRows(none)).toEqual([]);
  });

  it("says the total out of the maximum", () => {
    expect(totalText(11, 24)).toBe("11 / 24");
    expect(totalText(15.5, 24)).toBe("15.5 / 24");
    expect(totalText(null, 24)).toBe("– / 24");
    expect(totalText(3, null)).toBe("3");
  });

  it("heads a practice script and a missed seeded script with their own words", () => {
    expect(FEEDBACK_HEADING.practice).toBe("Practice script. Compare your marks with the lead marker's.");
    expect(FEEDBACK_HEADING.seed).toBe("This was a check script. Your marks were outside the tolerance. These are the lead marker's marks.");
  });
});

const GENERIC = "Something went wrong. Please try again.";

/** Every code the functions of Phase 3B Tasks 2 to 5 brought, by who meets it. */
const NEW_CODES = {
  // Task 2 (marking_checks_set, marking_open); Task 3 (a second pass assigned to a marker who saw a name); Task 4
  // (marking_second_add and marking_second_drop skip a piece); Task 5 (practice and seeded scripts, clearing and
  // pausing a marker, assigning to a marker not cleared or paused). The lead's and the admin's pages read them.
  staff: [
    "not_small_subject",
    "needs_two_markers",
    "no_lead",
    "marking_approved",
    "name_seen",
    "not_submitted",
    "settled",
    "with_lead",
    "already",
    "not_waiting",
    "not_yours",
    "too_many",
    "practice_first",
    "paused",
    "practice_wait",
    "practice_not_ready",
    "locked",
  ],
  // Task 4 (marking_save after the lead settled); Task 5 (Next script, opening, saving and submitting).
  marker: ["settled", "paused", "locked", "practice_wait", "practice_not_ready"],
  // Task 5: why a practice or seeded script cannot be made or retired (a conflict's reason).
  standardConflicts: ["switched_off", "already", "retired"],
} as const;

describe("messages", () => {
  it("message_for_each_new_code: every code of Tasks 2 to 5 has its sentence", () => {
    for (const code of NEW_CODES.staff) expect(markingMessageFor(code), code).not.toBe(GENERIC);
    for (const code of NEW_CODES.marker) expect(markingScreenMessageFor(code), code).not.toBe(GENERIC);
    for (const reason of NEW_CODES.standardConflicts) expect(standardMessageFor("conflict", reason), reason).not.toBe(GENERIC);
    for (const code of ["not_yours", "too_many"]) expect(standardMessageFor(code), code).not.toBe(GENERIC);
    for (const code of ["name_seen", "practice_first", "paused"]) expect(allocationMessageFor(code, "admin"), code).not.toBe(GENERIC);
  });

  it("says the pieces a second marking request skipped in plain words", () => {
    expect(markingMessageFor("not_submitted")).toBe("This script's first marking is not submitted yet.");
    expect(markingMessageFor("settled")).toBe("The lead marker has settled this script.");
    expect(markingMessageFor("with_lead")).toBe("This script is with the lead marker.");
    expect(markingMessageFor("already")).toBe("This script already has a second marking, or is waiting for one.");
    expect(markingMessageFor("not_waiting")).toBe("This script is not waiting for a second marker.");
  });

  it("uses one sentence for a code wherever staff meet it", () => {
    for (const code of ["name_seen", "practice_first", "paused"]) expect(markingMessageFor(code)).toBe(allocationMessageFor(code, "admin"));
    for (const code of ["not_yours", "too_many"]) expect(markingMessageFor(code)).toBe(standardMessageFor(code));
    for (const code of ["practice_wait", "practice_not_ready", "locked"]) expect(markingMessageFor(code)).toBe(markingScreenMessageFor(code));
  });
});
