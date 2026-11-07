// Marks the examiner puts on a paper, modelled on the RM Assessor 3 palette.
// Positions are fractions of the page (0 to 1), so they stay in place at any zoom.

// Standard codes, drawn as red boxed text on the paper.
export const BOX_KINDS = ["XP", "SEEN", "SF", "TE", "BP", "AE", "ECF", "L1", "L2", "L3", "POT", "BOD", "CON"] as const;
export type BoxKind = (typeof BOX_KINDS)[number];

// Every mark that is placed as a single stamp.
export const STAMP_KINDS = ["tick", "cross", "error", "caret", ...BOX_KINDS] as const;
export type StampKind = (typeof STAMP_KINDS)[number];

// Measuring tools: a ruler line, a box with its size, and a protractor angle.
export type Tool = "select" | "pen" | "highlight" | "text" | "ruler" | "box" | "protractor" | StampKind;

const STAMP_SET = new Set<string>(STAMP_KINDS);

export function isStamp(tool: Tool): tool is StampKind {
  return STAMP_SET.has(tool);
}

export type Annotation = {
  id: string;
  page: number;
  kind: Exclude<Tool, "select">;
  x: number;
  y: number;
  // Strokes, rulers, boxes and protractors: points as fractions of the page.
  points?: [number, number][];
  text?: string;
};

const key = (paperId: string) => `stem-paper-ann-${paperId}`;

export function loadAnnotations(paperId: string): Annotation[] {
  try {
    const raw = window.localStorage.getItem(key(paperId));
    return raw ? (JSON.parse(raw) as Annotation[]) : [];
  } catch {
    return [];
  }
}

export function saveAnnotations(paperId: string, list: Annotation[]): boolean {
  try {
    window.localStorage.setItem(key(paperId), JSON.stringify(list));
    return true;
  } catch {
    return false;
  }
}

export const TOOL_LABELS: Record<Exclude<Tool, "select">, string> = {
  tick: "Tick",
  cross: "Cross",
  error: "Wrong sign",
  caret: "Insert ^",
  XP: "XP",
  SEEN: "SEEN",
  SF: "SF",
  TE: "TE",
  BP: "BP",
  AE: "AE",
  ECF: "ECF",
  L1: "L1",
  L2: "L2",
  L3: "L3",
  POT: "POT",
  BOD: "BOD",
  CON: "CON",
  pen: "Red pen",
  highlight: "Highlighter",
  text: "Red note",
  ruler: "Ruler",
  box: "Shape",
  protractor: "Protractor",
};
