/** What the marker reads after a practice script, or a seeded script marked outside tolerance (marking_feedback): their
 * marks beside the lead marker's, in the panel's own shape, and the panel's words. The parser keeps only the fields it
 * knows; the function names nobody, and answers only the marking's own marker once its feedback was shown. */
import { formatMark } from "@/lib/marking-screen";

export type FeedbackQuestion = {
  questionId: string;
  /** As printed on the paper: "2(b)(i)". */
  label: string;
  max: number | null;
  /** The marker's mark (null for NR, or none). */
  yours: number | null;
  yoursNa: boolean;
  lead: number | null;
  leadNa: boolean;
  /** Outside the exam's tolerance for this question. */
  out: boolean;
};
export type Feedback = {
  use: "practice" | "seed";
  total: number | null;
  leadTotal: number | null;
  maxTotal: number | null;
  /** The lead marker's note on the script, or null. */
  note: string | null;
  questions: FeedbackQuestion[];
};

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);
const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** marking_feedback's answer, or the code it was refused with ("internal" when the answer makes no sense). */
export function parseFeedback(data: unknown): { ok: true; feedback: Feedback } | { ok: false; code: string } {
  const d = obj(data);
  if (!d) return { ok: false, code: "internal" };
  if (d.ok !== true) return { ok: false, code: str(d.code) ?? "internal" };
  if (d.use !== "practice" && d.use !== "seed") return { ok: false, code: "internal" };
  const questions = (Array.isArray(d.questions) ? d.questions : []).flatMap((v): FeedbackQuestion[] => {
    const q = obj(v);
    const questionId = str(q?.question_id);
    const label = str(q?.label);
    if (!q || !questionId || label === null) return [];
    return [{
      questionId,
      label,
      max: num(q.max),
      yours: num(q.yours),
      yoursNa: q.yours_na === true,
      lead: num(q.lead),
      leadNa: q.lead_na === true,
      out: q.out === true,
    }];
  });
  return {
    ok: true,
    feedback: { use: d.use, total: num(d.total), leadTotal: num(d.lead_total), maxTotal: num(d.max_total), note: str(d.note), questions },
  };
}

/** A mark as the marker reads it: "NR", "3", "2.5", or a dash for none. */
export function markText(mark: number | null, na: boolean): string {
  if (na) return "NR";
  return mark === null ? "–" : formatMark(mark);
}

/** A total out of the piece's maximum: "11 / 24" (a dash for none; the total alone when the maximum is not known). */
export function totalText(total: number | null, max: number | null): string {
  const t = total === null ? "–" : formatMark(total);
  return max === null ? t : `${t} / ${formatMark(max)}`;
}

/** The table's rows, in paper order: each question with both marks, and whether they differ by more than the
 * tolerance ("Different"). */
export function feedbackRows(f: Feedback): { label: string; yours: string; lead: string; different: boolean }[] {
  return f.questions.map((q) => ({ label: q.label, yours: markText(q.yours, q.yoursNa), lead: markText(q.lead, q.leadNa), different: q.out }));
}

/** When the feedback could not be read (no connection, or an answer that makes no sense). */
export const FEEDBACK_FAILED = "The lead marker's marks could not be loaded. Try again.";

/** The panel's heading. A seeded script says what it was only once it was marked outside tolerance. */
export const FEEDBACK_HEADING: Record<Feedback["use"], string> = {
  practice: "Practice script. Compare your marks with the lead marker's.",
  seed: "This was a check script. Your marks were outside the tolerance. These are the lead marker's marks.",
};
