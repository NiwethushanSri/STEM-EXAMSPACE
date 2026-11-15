import type { PaperState, SubjectGroup } from "@/lib/home-exams";
import s from "./home.module.css";

/** The GCSE and A level subjects the centre runs mocks in, in display order. */
export const SUBJECTS = ["Maths", "Further Maths", "Physics", "Chemistry", "Biology", "Computer Science"] as const;

const ICON = {
  maths: "maths",
  "further maths": "further-maths",
  physics: "physics",
  chemistry: "chemistry",
  biology: "biology",
  "computer science": "computer-science",
} as const;

export function iconFor(subject: string) {
  return ICON[subject.toLowerCase() as keyof typeof ICON] ?? "exam";
}

/** Subject colour follows the logo emblem: maths green, sciences teal, computing orange. */
export const TONE: Record<SubjectGroup, string> = {
  maths: s.toneMaths,
  science: s.toneScience,
  computing: s.toneComputing,
  other: s.toneOther,
};

export const PILL: Record<PaperState, string> = {
  open: s.pillOpen,
  few: s.pillFew,
  full: s.pillFull,
  closed: s.pillClosed,
};
