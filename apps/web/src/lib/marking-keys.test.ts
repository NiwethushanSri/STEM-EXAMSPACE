import { describe, expect, it } from "vitest";
import { keyAction } from "./marking-keys";

const k = (key: string, over: Partial<{ ctrl: boolean; meta: boolean; shift: boolean; typing: boolean }> = {}) => ({
  key, ctrl: false, meta: false, shift: false, typing: false, ...over,
});
const c = { max: 4, step: 1 as const };

describe("marking keys", () => {
  it("digits_set_the_mark_only_up_to_nine", () => {
    expect(keyAction(k("3"), c)).toEqual({ type: "mark", value: 3 });
    expect(keyAction(k("0"), { max: 9, step: 1 })).toEqual({ type: "mark", value: 0 });
    expect(keyAction(k("3"), { max: 10, step: 1 })).toEqual({ type: "focus_mark" });
  });

  it("dot, N and tools", () => {
    expect(keyAction(k("."), { max: 4, step: 0.5 })).toEqual({ type: "half" });
    expect(keyAction(k("."), c)).toBeNull();
    expect(keyAction(k("n"), c)).toEqual({ type: "nr" });
    expect(keyAction(k("N"), c)).toEqual({ type: "nr" });
    const tools: Record<string, string> = {
      v: "select", t: "tick", x: "cross", p: "pen", h: "highlight", c: "text", r: "ruler", e: "eraser", b: "BOD", f: "ECF", s: "SEEN",
    };
    for (const [key, tool] of Object.entries(tools)) expect(keyAction(k(key), c)).toEqual({ type: "tool", tool });
  });

  it("navigation, zoom and delete", () => {
    expect(keyAction(k("ArrowUp"), c)).toEqual({ type: "prev_question" });
    expect(keyAction(k("ArrowDown"), c)).toEqual({ type: "next_question" });
    expect(keyAction(k("ArrowLeft"), c)).toEqual({ type: "prev_page" });
    expect(keyAction(k("ArrowRight"), c)).toEqual({ type: "next_page" });
    expect(keyAction(k("Enter"), c)).toEqual({ type: "next_question" });
    expect(keyAction(k("]"), c)).toEqual({ type: "zoom_in" });
    expect(keyAction(k("["), c)).toEqual({ type: "zoom_out" });
    expect(keyAction(k("\\"), c)).toEqual({ type: "fit_width" });
    expect(keyAction(k("Delete"), c)).toEqual({ type: "delete" });
    expect(keyAction(k("Backspace"), c)).toEqual({ type: "delete" });
  });

  it("undo and redo", () => {
    expect(keyAction(k("z", { ctrl: true }), c)).toEqual({ type: "undo" });
    expect(keyAction(k("z", { meta: true }), c)).toEqual({ type: "undo" });
    expect(keyAction(k("Z", { ctrl: true, shift: true }), c)).toEqual({ type: "redo" });
    expect(keyAction(k("c", { ctrl: true }), c)).toBeNull();
  });

  it("shortcuts_are_off_while_typing", () => {
    for (const key of ["3", "t", "n", "ArrowUp", "Enter", "Delete", "Backspace", "]"]) {
      expect(keyAction(k(key, { typing: true }), c)).toBeNull();
    }
    expect(keyAction(k("z", { ctrl: true, typing: true }), c)).toEqual({ type: "undo" });
    expect(keyAction(k("z", { meta: true, shift: true, typing: true }), c)).toEqual({ type: "redo" });
  });
});
