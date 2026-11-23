import type { Tool } from "./annotations";

export type KeyTool = Tool | "eraser";

export type Action =
  | { type: "mark"; value: number }
  | { type: "focus_mark" }
  | { type: "half" }
  | { type: "nr" }
  | { type: "tool"; tool: KeyTool }
  | { type: "prev_question" }
  | { type: "next_question" }
  | { type: "prev_page" }
  | { type: "next_page" }
  | { type: "zoom_in" }
  | { type: "zoom_out" }
  | { type: "fit_width" }
  | { type: "undo" }
  | { type: "redo" }
  | { type: "delete" };

const TOOL_KEYS: Record<string, KeyTool> = {
  v: "select", t: "tick", x: "cross", p: "pen", h: "highlight", c: "text", r: "ruler", e: "eraser", b: "BOD", f: "ECF", s: "SEEN",
};

const NAMED: Record<string, Action> = {
  ArrowUp: { type: "prev_question" },
  ArrowDown: { type: "next_question" },
  ArrowLeft: { type: "prev_page" },
  ArrowRight: { type: "next_page" },
  Enter: { type: "next_question" },
  "]": { type: "zoom_in" },
  "[": { type: "zoom_out" },
  "\\": { type: "fit_width" },
  Delete: { type: "delete" },
  Backspace: { type: "delete" },
};

/** What a key press means on the marking screen, or null when it means nothing (or the marker is typing). */
export function keyAction(
  e: { key: string; ctrl: boolean; meta: boolean; shift: boolean; alt: boolean; typing: boolean },
  ctx: { max: number; step: 0.5 | 1 },
): Action | null {
  if (e.alt) return null;
  const lower = e.key.toLowerCase();
  if (e.ctrl || e.meta) {
    if (lower !== "z") return null;
    return e.shift ? { type: "redo" } : { type: "undo" };
  }
  if (e.typing) return null;
  if (/^[0-9]$/.test(e.key)) return ctx.max <= 9 ? { type: "mark", value: Number(e.key) } : { type: "focus_mark" };
  if (e.key === ".") return ctx.step === 0.5 ? { type: "half" } : null;
  if (lower === "n") return { type: "nr" };
  const tool = TOOL_KEYS[lower];
  if (tool) return { type: "tool", tool };
  return NAMED[e.key] ?? null;
}
