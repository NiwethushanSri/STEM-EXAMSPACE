/**
 * Canonical index number SE-<year>-<sequence>. Tolerates case, spaces and any mix of hyphens and
 * spaces ("se 2026-0142"). Anything that does not look like an index number is returned upper-cased
 * with whitespace removed, so the server's own format check rejects it.
 * Keep in sync with supabase/functions/_shared/validate.ts (normaliseIndex).
 */
export function normaliseIndexNumber(raw: string): string {
  const m = /^SE(\d{4})(\d{4,})$/.exec(raw.toUpperCase().replace(/[\s-]+/g, ""));
  return m ? `SE-${m[1]}-${m[2]}` : raw.toUpperCase().replace(/\s+/g, "");
}
