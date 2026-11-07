import { afterEach, describe, expect, it, vi } from "vitest";
import { createStemClient } from "./supabase";
import { approveStudent, callFunction, indexLogin } from "./functions";

function client(fetchImpl: typeof fetch) {
  vi.stubGlobal("fetch", fetchImpl); // must precede client creation
  return createStemClient("http://localhost:54321", "anon-key", { persistSession: false });
}

afterEach(() => vi.unstubAllGlobals());

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

describe("callFunction", () => {
  it("returns data on 200", async () => {
    const c = client((async () => json(200, { emailSent: true })) as typeof fetch);
    expect(await callFunction(c, "reject-student", { studentId: "x" })).toEqual({ data: { emailSent: true } });
  });
  it("returns the server error body on 409", async () => {
    const c = client((async () => json(409, { error: { code: "conflict", message: "x" } })) as typeof fetch);
    expect(await callFunction(c, "approve-student", { studentId: "x" })).toEqual({
      error: { code: "conflict", message: "x" },
    });
  });
  it("maps network failure to internal without throwing", async () => {
    const c = client((async () => {
      throw new TypeError("network down");
    }) as typeof fetch);
    expect(await approveStudent(c, "x")).toEqual({
      error: { code: "internal", message: "Something went wrong. Please try again." },
    });
  });
  it("falls back to messageFor when the server sends no message", async () => {
    const c = client((async () => json(429, { error: { code: "rate_limited" } })) as typeof fetch);
    expect(await indexLogin(c, "SE-2026-0001", "pw")).toEqual({
      error: { code: "rate_limited", message: "Too many attempts. Try again later." },
    });
  });
  it("non-JSON error body becomes internal", async () => {
    const c = client((async () => new Response("boom", { status: 500 })) as typeof fetch);
    const r = await callFunction(c, "delete-my-account", {});
    expect("error" in r && r.error.code).toBe("internal");
  });
});
