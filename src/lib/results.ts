import type { Child } from "@/lib/site-data";

// Shared helpers used by both server and client components.
export function relationOf(child: Child) {
  return child.gender === "Female" ? "Daughter" : "Son";
}

export function average(child: Child) {
  if (child.results.length === 0) return 0;
  return Math.round(child.results.reduce((s, r) => s + r.mark, 0) / child.results.length);
}
