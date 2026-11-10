/** Turning free text from the bookings search box into safe, parameterised filters. */

/** Escapes LIKE wildcards so user text matches literally. */
export function escapeLike(s: string): string {
  return s.replace(/[\\%_]/g, (c) => "\\" + c);
}

/**
 * Splits search text into at most 4 words of up to 40 characters. Every word must match the student's first
 * name, last name or index number. Commas, brackets and quotes are kept as ordinary characters: each word goes
 * to PostgREST as the value of a single `ilike` filter, never inside an `or(...)` string.
 */
export function searchWords(raw: string | undefined | null): string[] {
  return (raw ?? "")
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 4)
    .map((w) => w.slice(0, 40));
}

/** The ilike pattern for one word. */
export const likePattern = (word: string) => "%" + escapeLike(word) + "%";
