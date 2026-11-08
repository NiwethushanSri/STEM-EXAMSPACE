export const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** Canonical index number: SE-<year>-<sequence>. Tolerates case, spaces and mixed hyphens ("se 2026-0142"). */
export function normaliseIndex(raw: string): string {
  const s = raw.toUpperCase().replace(/[\s-]+/g, "");
  const m = /^SE(\d{4})(\d{4,})$/.exec(s);
  return m ? `SE-${m[1]}-${m[2]}` : raw.toUpperCase().replace(/\s+/g, "");
}

/** A real calendar date in the past (YYYY-MM-DD) for a person aged 8 to 25 today. */
export function validPastDate(s: unknown, now = new Date()): s is string {
  if (typeof s !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  const d = new Date(`${s}T00:00:00Z`);
  if (Number.isNaN(d.getTime()) || d.toISOString().slice(0, 10) !== s) return false;
  if (d.getTime() >= now.getTime()) return false;
  let age = now.getUTCFullYear() - d.getUTCFullYear();
  if (now.getUTCMonth() < d.getUTCMonth() || (now.getUTCMonth() === d.getUTCMonth() && now.getUTCDate() < d.getUTCDate())) age--;
  return age >= 8 && age <= 25;
}

/** Trimmed string within [min, max] characters, else null. */
export function str(v: unknown, min: number, max: number): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim();
  return t.length >= min && t.length <= max ? t : null;
}

/** Lowercased, trimmed, valid-shaped email (<= 254 chars), else null. */
export function email(v: unknown): string | null {
  if (typeof v !== "string") return null;
  const t = v.trim().toLowerCase();
  return t.length <= 254 && EMAIL.test(t) ? t : null;
}
