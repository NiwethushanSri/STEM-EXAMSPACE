import "server-only";
import * as pdfjs from "pdfjs-dist/legacy/build/pdf.mjs";

export type DetectedQuestion = { id: string; label: string; max: number };

export type PaperReading = {
  pages: number;
  hasTextLayer: boolean;
  candidateNumber: string;
  candidateName: string;
  questions: DetectedQuestion[];
};

// Reads a typed PDF (one with a text layer). Handwritten scans have no text
// layer, so those return hasTextLayer: false and need manual entry for now.
export async function readPaper(data: Uint8Array): Promise<PaperReading> {
  const doc = await pdfjs.getDocument({ data, useSystemFonts: true, isEvalSupported: false }).promise;

  let text = "";
  for (let p = 1; p <= doc.numPages; p++) {
    const page = await doc.getPage(p);
    const content = await page.getTextContent();
    text += content.items.map((item) => ("str" in item ? item.str : "")).join(" ") + "\n";
  }

  const candidateNumber = readField(text, /Candidate Number:\s*([A-Za-z0-9][A-Za-z0-9\- ]*)/);
  const candidateName = readField(text, /Candidate Name:\s*([A-Za-z][A-Za-z'\- ]*)/);

  // Split the paper at each "Q1." style marker, then find that question's
  // "(Total for question = N marks)" line.
  const markers = [...text.matchAll(/\bQ(\d+)\./g)];
  const questions: DetectedQuestion[] = [];
  markers.forEach((m, i) => {
    const start = m.index ?? 0;
    const end = i + 1 < markers.length ? markers[i + 1].index ?? text.length : text.length;
    const segment = text.slice(start, end);
    const total = segment.match(/Total for question\s*=\s*(\d+)\s*marks?/i);
    const label = `Q${m[1]}`;
    if (!questions.some((q) => q.label === label)) {
      questions.push({ id: label.toLowerCase(), label, max: total ? Number(total[1]) : 0 });
    }
  });

  return {
    pages: doc.numPages,
    hasTextLayer: text.replace(/\s+/g, "").length > 200,
    candidateNumber,
    candidateName,
    questions,
  };
}

// Returns the typed value, or "" when the field is blank (only underscores).
function readField(text: string, pattern: RegExp) {
  const match = text.match(pattern);
  if (!match) return "";
  return match[1].replace(/\s+/g, " ").trim();
}
