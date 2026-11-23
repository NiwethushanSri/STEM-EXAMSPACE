/** Signed links to marking pictures (Phase 3B Task 1, Ruling R12). The Edge Function marking-pictures asks the
 * database, as the signed-in user, which of a piece's pages they may see now, and signs those pictures for 120
 * seconds; the browser never holds a picture's path and cannot make a link itself. Used by the marking screen and the
 * lead's page viewer. */
import { createClient } from "@/lib/supabase/client";

export type PictureLinks = { ok: true; urls: Record<string, string> } | { ok: false; code: string; status: number | null };

/** How long a link lasts (seconds), as the function signs it. */
export const PICTURE_LINK_SECONDS = 120;
/** The most pages one request may ask for. */
export const PICTURE_LINK_MAX = 40;

const SIGNED = "/storage/v1/object/sign/script-pages/";

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : null);

/** The links of a success answer by page id, each put on this site's Supabase address (the function may sign with an
 * address only it can reach, as the local stack's does). A link that is not a signed script-pages link is left out.
 * Null when the answer is not one. */
function linksOf(data: unknown): Record<string, string> | null {
  const d = obj(data);
  if (d?.ok !== true || !Array.isArray(d.urls)) return null;
  const base = process.env.NEXT_PUBLIC_SUPABASE_URL ?? "";
  const out: Record<string, string> = {};
  for (const item of d.urls) {
    const u = obj(item);
    const pageId = typeof u?.page_id === "string" ? u.page_id : null;
    const url = typeof u?.url === "string" ? u.url : null;
    if (!pageId || !url) continue;
    try {
      const parsed = new URL(url);
      if (!parsed.pathname.startsWith(SIGNED)) continue;
      out[pageId] = new URL(parsed.pathname + parsed.search, base).toString();
    } catch {
      // Not a link: left out.
    }
  }
  return out;
}

/** The refusal of a failed call: its code (ours, or the gateway's status alone) and its HTTP status, or no status for
 * a call that never got an answer (no connection). */
async function refusalOf(error: unknown): Promise<{ ok: false; code: string; status: number | null }> {
  // Duck-typed, as callFunction in @stem/shared does: the response is the error's context for an HTTP answer.
  const ctx = obj(error)?.context as { status?: unknown; json?: unknown } | undefined;
  if (!ctx || typeof ctx.status !== "number" || typeof ctx.json !== "function") return { ok: false, code: "internal", status: null };
  let code = "internal";
  try {
    const body = obj(await (ctx as { json: () => Promise<unknown> }).json());
    const c = body?.code ?? obj(body?.error)?.code;
    if (typeof c === "string") code = c;
  } catch {
    // No body of ours: the status says enough.
  }
  return { ok: false, code, status: ctx.status };
}

/** Links for up to PICTURE_LINK_MAX pages of a piece, by page id. Never throws: a refusal gives the function's code
 * and status (4xx: the pages may not be seen now), a failure to ask gives status null. */
export async function fetchPictureLinks(unitId: string, pageIds: string[]): Promise<PictureLinks> {
  try {
    const { data, error } = await createClient().functions.invoke("marking-pictures", { body: { unit_id: unitId, page_ids: pageIds } });
    if (error) return await refusalOf(error);
    const urls = linksOf(data);
    return urls ? { ok: true, urls } : { ok: false, code: "internal", status: null };
  } catch {
    return { ok: false, code: "internal", status: null };
  }
}
