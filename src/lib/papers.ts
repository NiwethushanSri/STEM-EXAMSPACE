import { children, type Child } from "@/lib/site-data";

export type PaperQuestion = { id: string; label: string; max: number };

export type StudentPaper = {
  id: string;
  fileName: string;
  examTitle: string;
  indexNumber: string;
  candidateName: string;
  studentId: string;
  uploadedAt: string;
  status: "Awaiting marking" | "Marked";
  questions: PaperQuestion[];
  // Marks per question id, e.g. { q1: 6, q2: 9 }. Filled in by the examiner.
  marks: Record<string, number>;
  feedback: string;
};

export type MatchResult =
  | { status: "empty" }
  | { status: "no-index"; child?: undefined }
  | { status: "name-mismatch"; child: Child }
  | { status: "matched"; child: Child };

const STORAGE_KEY = "stem-student-papers";

// Stored in a question's marks when the student gave no answer (NR). It counts as 0.
export const NO_RESPONSE = -1;

// Matches a paper to a student by index number first, then checks the name.
export function matchStudent(indexNumber: string, candidateName: string): MatchResult {
  const idx = indexNumber.replace(/\s+/g, "").toUpperCase();
  if (!idx) return { status: "empty" };

  const child = children.find((c) => c.indexNumber.replace(/\s+/g, "").toUpperCase() === idx);
  if (!child) return { status: "no-index" };

  const name = candidateName.trim().toLowerCase().replace(/\s+/g, " ");
  if (name && name !== child.name.toLowerCase()) return { status: "name-mismatch", child };

  return { status: "matched", child };
}

// Mockup storage: papers live in this browser only, so they show up on the
// examiner page of the same browser. A real database replaces this later.
export function loadPapers(): StudentPaper[] {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    return raw ? (JSON.parse(raw) as StudentPaper[]) : [];
  } catch {
    return [];
  }
}

export function savePapers(papers: StudentPaper[]) {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(papers));
  } catch {
    // Storage can be blocked (private mode). The page still works for this visit.
  }
}

// The PDF itself is stored as base64 under its own key. Browser storage is small
// (about 5 MB), so a large set of papers can run out of room. Returns false then.
const fileKey = (id: string) => `stem-paper-file-${id}`;

export async function saveFile(id: string, file: File): Promise<boolean> {
  try {
    const bytes = new Uint8Array(await file.arrayBuffer());
    let binary = "";
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    window.localStorage.setItem(fileKey(id), btoa(binary));
    return true;
  } catch {
    return false;
  }
}

export function loadFile(id: string): Uint8Array | null {
  try {
    const raw = window.localStorage.getItem(fileKey(id));
    if (!raw) return null;
    const binary = atob(raw);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}
