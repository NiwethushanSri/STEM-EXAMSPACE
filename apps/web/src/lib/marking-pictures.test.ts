import { beforeEach, describe, expect, it, vi } from "vitest";

const invoke = vi.fn();
vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({ functions: { invoke } }) }));

import { fetchPictureLinks } from "./marking-pictures";
import { accessCheckOutcome } from "./marking-screen";

const UNIT = "11111111-1111-4111-8111-111111111111";
const P1 = "22222222-2222-4222-8222-222222222221";
const P2 = "22222222-2222-4222-8222-222222222222";
const SITE = "http://127.0.0.1:54321";
/** As the local functions server signs: with an address only it can reach. */
const signed = (path: string) => `http://kong:8000/storage/v1/object/sign/script-pages/${path}?token=abc.def`;
/** What supabase-js gives for a non-2xx answer: the response is the error's context. */
const httpError = (status: number, body: unknown) => ({ data: null, error: { name: "FunctionsHttpError", context: new Response(JSON.stringify(body), { status }) } });

beforeEach(() => {
  invoke.mockReset();
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", SITE);
});

describe("fetchPictureLinks", () => {
  it("picture_links_are_keyed_by_page_id", async () => {
    invoke.mockResolvedValue({
      data: { ok: true, expires_in: 120, urls: [{ page_id: P2, url: signed("e/u/1-1/1-marking.jpg") }, { page_id: P1, url: signed("e/u/1-1/0-marking.jpg") }] },
      error: null,
    });
    const r = await fetchPictureLinks(UNIT, [P1, P2]);
    expect(invoke).toHaveBeenCalledWith("marking-pictures", { body: { unit_id: UNIT, page_ids: [P1, P2] } });
    // Each link is the page's own, on this site's Supabase address.
    expect(r).toEqual({
      ok: true,
      urls: {
        [P1]: `${SITE}/storage/v1/object/sign/script-pages/e/u/1-1/0-marking.jpg?token=abc.def`,
        [P2]: `${SITE}/storage/v1/object/sign/script-pages/e/u/1-1/1-marking.jpg?token=abc.def`,
      },
    });
  });

  it("keeps no link that is not a signed script-pages link, and no page without an id", async () => {
    invoke.mockResolvedValue({
      data: {
        ok: true,
        urls: [
          { page_id: P1, url: "https://elsewhere.example/storage/v1/object/public/script-pages/x.jpg" },
          { page_id: P2, url: "not a url" },
          { url: signed("e/u/1-1/0-marking.jpg") },
        ],
      },
      error: null,
    });
    expect(await fetchPictureLinks(UNIT, [P1, P2])).toEqual({ ok: true, urls: {} });
    invoke.mockResolvedValue({ data: { ok: true }, error: null });
    expect(await fetchPictureLinks(UNIT, [P1])).toEqual({ ok: false, code: "internal", status: null });
  });

  it("a_4xx_means_gone_and_a_network_error_means_unknown", async () => {
    invoke.mockResolvedValue(httpError(403, { ok: false, code: "forbidden" }));
    const refused = await fetchPictureLinks(UNIT, [P1]);
    expect(refused).toEqual({ ok: false, code: "forbidden", status: 403 });
    expect(accessCheckOutcome(refused)).toBe("gone");

    invoke.mockResolvedValue(httpError(409, { ok: false, code: "on_hold" }));
    const held = await fetchPictureLinks(UNIT, [P1]);
    expect(held).toEqual({ ok: false, code: "on_hold", status: 409 });
    expect(accessCheckOutcome(held)).toBe("gone");

    // The gateway's own 401 has no code of ours.
    invoke.mockResolvedValue(httpError(401, { msg: "Invalid JWT" }));
    expect(accessCheckOutcome(await fetchPictureLinks(UNIT, [P1]))).toBe("gone");

    // No connection: supabase-js puts the failure itself in the context, with no status.
    invoke.mockResolvedValue({ data: null, error: { name: "FunctionsFetchError", context: new TypeError("Failed to fetch") } });
    const offline = await fetchPictureLinks(UNIT, [P1]);
    expect(offline).toEqual({ ok: false, code: "internal", status: null });
    expect(accessCheckOutcome(offline)).toBe("unknown");

    invoke.mockResolvedValue(httpError(500, { ok: false, code: "internal" }));
    expect(accessCheckOutcome(await fetchPictureLinks(UNIT, [P1]))).toBe("unknown");

    invoke.mockRejectedValue(new Error("boom"));
    expect(accessCheckOutcome(await fetchPictureLinks(UNIT, [P1]))).toBe("unknown");

    invoke.mockResolvedValue({ data: { ok: true, expires_in: 120, urls: [{ page_id: P1, url: signed("e/u/1-1/0-marking.jpg") }] }, error: null });
    expect(accessCheckOutcome(await fetchPictureLinks(UNIT, [P1]))).toBe("ok");
  });
});
