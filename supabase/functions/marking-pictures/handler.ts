// Signs the links to the marking pictures of a piece's pages (Phase 3B Task 1; Ruling R12). The database decides, as
// the caller, which pictures they may see now and gives their paths (marking_picture_paths, migration
// 20261123000002); this function signs exactly those paths, for 120 seconds, with the service role. Markers and leads
// never hold a path and cannot make a link themselves: no storage policy lets them read script-pages.
//
// POST {unit_id, page_ids} (1 to 40 page ids) with the caller's token:
//   200 {ok: true, expires_in: 120, urls: [{page_id, url}]}
//   400 {ok: false, code: invalid_input}; 401 no token; 403 {ok: false, code} for a refusal, 409 for a passing one
//   (on_hold, pictures_updating, hold_expired, marking_closed); 500 {ok: false, code: internal}.
// Nothing else in the body is read: a path sent with the request is never signed.
// Logs hold codes only: never a path, a page, a name or a token.
import type { SupabaseClient } from "@supabase/supabase-js";
import type { AppRole } from "../_shared/auth.ts";
import { HttpError, jsonResponse } from "../_shared/errors.ts";

export const BUCKET = "script-pages";
/** How long a link lasts (seconds). */
export const LINK_SECONDS = 120;
/** The most pages one request may ask for. */
export const MAX_PAGES = 40;
/** Who may ask: every role that can mark or lead, and the admins. The database checks the rest. */
export const ROLES: AppRole[] = ["owner", "admin", "teacher", "corrector"];
/** Refusals that pass once the piece is free again: the screen covers the page and says why. */
const PASSING = new Set(["on_hold", "pictures_updating", "hold_expired", "marking_closed"]);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export interface Deps {
  requireCaller: (req: Request, allowed: AppRole[]) => Promise<{ id: string; role: AppRole }>;
  /** Runs the database call as the signed-in caller. */
  callerClient: (req: Request) => SupabaseClient;
  /** Signs the links (the service role). */
  serviceClient: () => SupabaseClient;
}

const refuse = (code: string, status: number) => jsonResponse({ ok: false, code }, status);

/** The paths marking_picture_paths gave, or null when its answer makes no sense. */
function pathsOf(data: unknown): { page_id: string; marking_path: string }[] | null {
  const paths = (data as { paths?: unknown } | null)?.paths;
  if (!Array.isArray(paths)) return null;
  const out: { page_id: string; marking_path: string }[] = [];
  for (const p of paths) {
    const pageId = (p as { page_id?: unknown })?.page_id;
    const path = (p as { marking_path?: unknown })?.marking_path;
    if (typeof pageId !== "string" || typeof path !== "string" || path === "") return null;
    out.push({ page_id: pageId, marking_path: path });
  }
  return out;
}

export function makeHandler(deps: Deps): (req: Request) => Promise<Response> {
  return async (req) => {
    if (req.method !== "POST") return refuse("invalid_input", 405);
    try {
      await deps.requireCaller(req, ROLES);
    } catch (e) {
      if (e instanceof HttpError) return refuse(e.code, e.status);
      throw e;
    }

    let body: { unit_id?: unknown; page_ids?: unknown };
    try {
      body = (await req.json()) as typeof body;
    } catch {
      return refuse("invalid_input", 400);
    }
    const unitId = body?.unit_id;
    const pageIds = body?.page_ids;
    if (
      typeof unitId !== "string" || !UUID.test(unitId) || !Array.isArray(pageIds) || pageIds.length < 1 ||
      pageIds.length > MAX_PAGES || !pageIds.every((p) => typeof p === "string" && UUID.test(p))
    ) {
      return refuse("invalid_input", 400);
    }

    const { data, error } = await deps.callerClient(req).rpc("marking_picture_paths", { p_unit: unitId, p_pages: pageIds });
    if (error) {
      console.error(`[marking-pictures] paths failed code=${error.code ?? "unknown"}`);
      return refuse("internal", 500);
    }
    const answer = data as { ok?: unknown; code?: unknown } | null;
    if (answer?.ok !== true) {
      const code = typeof answer?.code === "string" ? answer.code : "internal";
      console.log(`[marking-pictures] refused code=${code}`);
      return refuse(code, code === "invalid_input" ? 400 : code === "internal" ? 500 : PASSING.has(code) ? 409 : 403);
    }
    const paths = pathsOf(answer);
    if (!paths) {
      console.error("[marking-pictures] paths answer unreadable");
      return refuse("internal", 500);
    }

    const storage = deps.serviceClient().storage.from(BUCKET);
    const signed = await Promise.all(paths.map((p) => storage.createSignedUrl(p.marking_path, LINK_SECONDS)));
    const urls: { page_id: string; url: string }[] = [];
    for (const [i, s] of signed.entries()) {
      if (s.error || !s.data?.signedUrl) {
        console.error(`[marking-pictures] signing failed: ${s.error?.name ?? "no link"}`);
        return refuse("internal", 500);
      }
      urls.push({ page_id: paths[i].page_id, url: s.data.signedUrl });
    }
    return jsonResponse({ ok: true, expires_in: LINK_SECONDS, urls });
  };
}
