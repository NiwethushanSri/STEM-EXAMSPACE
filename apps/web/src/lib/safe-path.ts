/**
 * A post-sign-in return path must be a relative, same-site path. Anything else (absolute or
 * protocol-relative URLs, backslashes, control characters) is dropped.
 */
export function safeNext(raw: string | null | undefined): string | null {
  if (!raw || raw.length > 300) return null;
  if (!raw.startsWith("/") || raw.startsWith("//")) return null;
  for (const ch of raw) {
    const c = ch.charCodeAt(0);
    if (ch === "\\" || c < 0x20 || c === 0x7f) return null;
  }
  try {
    const u = new URL(raw, "http://internal.invalid");
    if (u.origin !== "http://internal.invalid") return null;
  } catch {
    return null;
  }
  return raw;
}
