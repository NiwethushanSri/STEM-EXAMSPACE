// A QR on a printed page holds exactly `SX1.<copy code>.<page>`; nothing else.
// The copy code is 8 Crockford base32 characters plus 1 check character (which may also be * ~ $ = U).
const PAYLOAD = /^SX1\.([0-9A-HJKMNP-TV-Z*~$=U]{9})\.([1-9][0-9]{0,2})$/;

export function parsePagePayload(text: string): { code: string; page: number } | null {
  const m = PAYLOAD.exec(text);
  return m ? { code: m[1], page: Number(m[2]) } : null;
}
