import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { requireCaller } from "../_shared/auth.ts";
import { handle } from "../_shared/errors.ts";
import { type Deps, LINK_SECONDS, makeHandler } from "./handler.ts";

// The handler with the database and storage clients stubbed: what marking_picture_paths answers is set per test, and
// every rpc and signing call is recorded. The SQL itself is tested in supabase/tests/054_marking_picture_links.test.sql.

const UNIT = "11111111-1111-4111-8111-111111111111";
const P1 = "22222222-2222-4222-8222-222222222221";
const P2 = "22222222-2222-4222-8222-222222222222";
const PATH1 = "exam/upload/1-1/0-marking.jpg";
const PATH2 = "exam/upload/1-1/1-marking.jpg";

type Rpc = { name: string; args: Record<string, unknown> };
type Sign = { bucket: string; path: string; seconds: number };

function stubs(answer: unknown, opts: { rpcError?: boolean } = {}) {
  const rpcs: Rpc[] = [];
  const signs: Sign[] = [];
  const db = {
    rpc: (name: string, args: Record<string, unknown>) => {
      rpcs.push({ name, args });
      return Promise.resolve(opts.rpcError ? { data: null, error: { code: "PGRST301" } } : { data: answer, error: null });
    },
  } as unknown as SupabaseClient;
  const svc = {
    storage: {
      from: (bucket: string) => ({
        createSignedUrl: (path: string, seconds: number) => {
          signs.push({ bucket, path, seconds });
          return Promise.resolve({ data: { signedUrl: `http://kong:8000/storage/v1/object/sign/${bucket}/${path}?token=t-${signs.length}` }, error: null });
        },
      }),
    },
  } as unknown as SupabaseClient;
  const deps: Deps = {
    requireCaller: () => Promise.resolve({ id: "33333333-3333-4333-8333-333333333333", role: "corrector" }),
    callerClient: () => db,
    serviceClient: () => svc,
  };
  return { deps, rpcs, signs };
}

const post = (body: unknown, token: string | null = "a-token") =>
  new Request("http://x.test/marking-pictures", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });

/** Runs fn with console.log and console.error captured. */
async function logged<T>(fn: () => Promise<T>): Promise<{ result: T; lines: string[] }> {
  const lines: string[] = [];
  const l = console.log, e = console.error;
  console.log = (...a: unknown[]) => void lines.push(a.join(" "));
  console.error = (...a: unknown[]) => void lines.push(a.join(" "));
  try {
    return { result: await fn(), lines };
  } finally {
    console.log = l;
    console.error = e;
  }
}

Deno.test("signs_only_what_the_database_returned", async () => {
  const s = stubs({ ok: true, paths: [{ page_id: P2, marking_path: PATH2 }, { page_id: P1, marking_path: PATH1 }] });
  const res = await handle(makeHandler(s.deps))(post({ unit_id: UNIT, page_ids: [P2, P1] }));
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(s.rpcs, [{ name: "marking_picture_paths", args: { p_unit: UNIT, p_pages: [P2, P1] } }]);
  assertEquals(s.signs.map((x) => [x.bucket, x.path]), [["script-pages", PATH2], ["script-pages", PATH1]]);
  assertEquals(body.ok, true);
  assertEquals(body.urls.map((u: { page_id: string }) => u.page_id), [P2, P1]);
  assert(body.urls[0].url.includes(PATH2) && body.urls[1].url.includes(PATH1), "each link is the one signed for its page");
  assertEquals(res.headers.get("access-control-allow-origin"), "*");
});

Deno.test("a_path_in_the_request_is_ignored", async () => {
  const s = stubs({ ok: true, paths: [{ page_id: P1, marking_path: PATH1 }] });
  const res = await handle(makeHandler(s.deps))(post({
    unit_id: UNIT,
    page_ids: [P1],
    path: "exam/upload/1-1/0-full.jpg",
    paths: ["exam/upload/1-1/0-full.jpg"],
    marking_path: "other/script/0-marking.jpg",
  }));
  assertEquals(res.status, 200);
  await res.body?.cancel();
  assertEquals(s.rpcs[0].args, { p_unit: UNIT, p_pages: [P1] });
  assertEquals(s.signs.map((x) => x.path), [PATH1]);

  // A request that names no page, or too many, or one that is not an id, is refused before the database is asked.
  for (const bad of [{ unit_id: UNIT, page_ids: [] }, { unit_id: UNIT, page_ids: Array(41).fill(P1) }, { unit_id: UNIT, page_ids: [PATH1] },
                     { unit_id: "nope", page_ids: [P1] }, { path: PATH1 }]) {
    const r = await handle(makeHandler(s.deps))(post(bad));
    assertEquals([r.status, (await r.json()).code], [400, "invalid_input"]);
  }
  assertEquals(s.rpcs.length, 1);
  assertEquals(s.signs.length, 1);
});

Deno.test("refusal_passes_the_code_and_signs_nothing", async () => {
  for (const [code, status] of [["forbidden", 403], ["not_found", 403], ["on_hold", 409], ["pictures_updating", 409], ["hold_expired", 409],
                                ["marking_closed", 409]] as const) {
    const s = stubs({ ok: false, code });
    const { result: res, lines } = await logged(() => handle(makeHandler(s.deps))(post({ unit_id: UNIT, page_ids: [P1, P2] })));
    assertEquals(res.status, status, code);
    assertEquals(await res.json(), { ok: false, code });
    assertEquals(s.signs, []);
    // The log says the code, and nothing about the piece, its pages or the caller.
    assertEquals(lines, [`[marking-pictures] refused code=${code}`]);
  }
  // A database error is a 500, unsigned, logged by its code only.
  const s = stubs(null, { rpcError: true });
  const { result: res, lines } = await logged(() => handle(makeHandler(s.deps))(post({ unit_id: UNIT, page_ids: [P1] })));
  assertEquals([res.status, (await res.json()).code], [500, "internal"]);
  assertEquals(s.signs, []);
  assertEquals(lines, ["[marking-pictures] paths failed code=PGRST301"]);
});

Deno.test("links_last_120_seconds", async () => {
  const s = stubs({ ok: true, paths: [{ page_id: P1, marking_path: PATH1 }, { page_id: P2, marking_path: PATH2 }] });
  const res = await handle(makeHandler(s.deps))(post({ unit_id: UNIT, page_ids: [P1, P2] }));
  assertEquals(LINK_SECONDS, 120);
  assertEquals(s.signs.map((x) => x.seconds), [120, 120]);
  assertEquals((await res.json()).expires_in, 120);
});

Deno.test("no_token_is_401", async () => {
  const never = (): SupabaseClient => {
    throw new Error("must not be called");
  };
  // The real caller check: with no Authorization header it answers 401 before any client is made.
  const deps: Deps = { requireCaller, callerClient: never, serviceClient: never };
  const res = await handle(makeHandler(deps))(post({ unit_id: UNIT, page_ids: [P1] }, null));
  assertEquals(res.status, 401);
  assertEquals(await res.json(), { ok: false, code: "unauthenticated" });
  const preflight = await handle(makeHandler(deps))(new Request("http://x.test/marking-pictures", { method: "OPTIONS" }));
  assertEquals(preflight.status, 204);
});
