// A QR on a printed page holds exactly `SX1.<copy code>.<page>`; nothing else.
// The copy code is 8 Crockford base32 characters plus 1 check character (which may also be * ~ $ = U).
const PAYLOAD = /^SX1\.([0-9A-HJKMNP-TV-Z*~$=U]{9})\.([1-9][0-9]{0,2})$/;

export function parsePagePayload(text: string): { code: string; page: number } | null {
  const m = PAYLOAD.exec(text);
  return m ? { code: m[1], page: Number(m[2]) } : null;
}

/** The lookup refuses more than this many codes in one call. */
export const LOOKUP_LIMIT = 1000;

/** Splits codes into lookup calls of at most LOOKUP_LIMIT; one call in the normal case, none for no codes. */
export function lookupChunks<T>(items: readonly T[], size: number = LOOKUP_LIMIT): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}
