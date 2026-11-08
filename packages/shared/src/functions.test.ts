import { afterEach, describe, expect, it, vi } from "vitest";
import { createStemClient, type StemClient } from "./supabase";
import {
  accountAdmin, approveStudent, callFunction, deleteMyAccount, indexLogin, inviteUser, parentChild, registerStudent, rejectStudent,
} from "./functions";

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

describe("callFunction hardening", () => {
  it("accepts a non-Response context exposing json()/status", async () => {
    const c = {
      functions: {
        invoke: async () => ({
          data: null,
          error: { context: { status: 409, json: async () => ({ error: { code: "conflict", message: "dup" } }) } },
        }),
      },
    } as unknown as StemClient;
    expect(await callFunction(c, "approve-student", {})).toEqual({ error: { code: "conflict", message: "dup" } });
  });
  it.each([
    [401, "unauthenticated"],
    [403, "forbidden"],
    [429, "rate_limited"],
    [502, "internal"],
  ])("gateway %i without a code maps to %s", async (status, code) => {
    const c = client((async () => json(status, { message: "gateway" })) as typeof fetch);
    const r = await callFunction(c, "approve-student", {});
    expect("error" in r && r.error.code).toBe(code);
  });
});

describe("helper payloads", () => {
  const calls: { url: string; body: unknown }[] = [];
  const spy = ((async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(input), body: JSON.parse(String(init?.body ?? "null")) });
    return json(200, {});
  }) as typeof fetch);
  const last = () => calls[calls.length - 1];
  const U = "11111111-1111-4111-8111-111111111111";

  it.each([
    ["approveStudent", (c: StemClient) => approveStudent(c, U), "approve-student", { studentId: U }],
    ["rejectStudent", (c: StemClient) => rejectStudent(c, U), "reject-student", { studentId: U }],
    ["indexLogin", (c: StemClient) => indexLogin(c, "SE-2026-0001", "pw"), "index-login", { indexNumber: "SE-2026-0001", password: "pw" }],
    [
      "inviteUser",
      (c: StemClient) => inviteUser(c, { email: "a@b.co", firstName: "A", lastName: "B", role: "teacher" }),
      "invite-user",
      { email: "a@b.co", firstName: "A", lastName: "B", role: "teacher" },
    ],
    ["accountAdmin suspend", (c: StemClient) => accountAdmin(c, { action: "suspend", userId: U }), "account-admin", { action: "suspend", userId: U }],
    ["accountAdmin edit_parent_email", (c: StemClient) => accountAdmin(c, { action: "edit_parent_email", userId: U, parentEmail: "p@b.co" }), "account-admin", { action: "edit_parent_email", userId: U, parentEmail: "p@b.co" }],
    ["accountAdmin clear", (c: StemClient) => accountAdmin(c, { action: "clear_stuck_invite", email: "a@b.co" }), "account-admin", { action: "clear_stuck_invite", email: "a@b.co" }],
    [
      "registerStudent",
      (c: StemClient) =>
        registerStudent(c, {
          firstName: "A", lastName: "B", email: "a@b.co", password: "longenough1", dateOfBirth: "2012-01-02",
          school: "S", parentName: "P", parentEmail: "p@b.co",
        }),
      "register-student",
      {
        firstName: "A", lastName: "B", email: "a@b.co", password: "longenough1", dateOfBirth: "2012-01-02",
        school: "S", parentName: "P", parentEmail: "p@b.co",
      },
    ],
    ["deleteMyAccount", (c: StemClient) => deleteMyAccount(c), "delete-my-account", {}],
    [
      "parentChild link",
      (c: StemClient) => parentChild(c, { action: "link", indexNumber: "SE-2026-0001", dateOfBirth: "2012-01-02" }),
      "parent-child",
      { action: "link", indexNumber: "SE-2026-0001", dateOfBirth: "2012-01-02" },
    ],
    [
      "parentChild register",
      (c: StemClient) =>
        parentChild(c, {
          action: "register",
          child: { firstName: "A", lastName: "B", school: "S", email: "c@d.co", dateOfBirth: "2012-01-02" },
        }),
      "parent-child",
      { action: "register", child: { firstName: "A", lastName: "B", school: "S", email: "c@d.co", dateOfBirth: "2012-01-02" } },
    ],
    ["parentChild approve", (c: StemClient) => parentChild(c, { action: "approve_link", requestId: U }), "parent-child", { action: "approve_link", requestId: U }],
  ] as const)("%s", async (_n, run, fn, payload) => {
    const c = client(spy);
    await run(c as StemClient);
    expect(last().url).toContain(`/functions/v1/${fn}`);
    expect(last().body).toEqual(payload);
  });
});
