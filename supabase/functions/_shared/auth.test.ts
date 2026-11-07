import { assert, assertEquals, assertNotEquals, assertRejects } from "jsr:@std/assert@1";
import { requireCaller } from "./auth.ts";
import { HttpError, handle } from "./errors.ts";
import { createTestUser, deleteUsers, service, type TestUser } from "./test_helpers.ts";

const reqWith = (token?: string) =>
  new Request("http://localhost/fn", {
    method: "POST",
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  });

async function withUsers(
  specs: Parameters<typeof createTestUser>[1][],
  fn: (users: TestUser[]) => Promise<void>,
) {
  const svc = service();
  const users: TestUser[] = [];
  try {
    for (const s of specs) users.push(await createTestUser(svc, s));
    await fn(users);
  } finally {
    await deleteUsers(svc, users);
  }
}

Deno.test("requireCaller: no Authorization header -> 401 unauthenticated", async () => {
  const e = await assertRejects(() => requireCaller(reqWith(), ["admin"]), HttpError);
  assertEquals(e.status, 401);
  assertEquals(e.code, "unauthenticated");
});

Deno.test("requireCaller: garbage token -> 401 unauthenticated", async () => {
  const e = await assertRejects(() => requireCaller(reqWith("not-a-jwt"), ["admin"]), HttpError);
  assertEquals(e.status, 401);
  assertEquals(e.code, "unauthenticated");
});

Deno.test("requireCaller: student with allowed=[admin] -> 403 forbidden; role from DB not JWT metadata", async () => {
  await withUsers([{ role: "student", status: "active", metadata: { role: "owner" } }], async ([u]) => {
    const e = await assertRejects(() => requireCaller(reqWith(u.token), ["admin"]), HttpError);
    assertEquals(e.status, 403);
    assertEquals(e.code, "forbidden");
  });
});

Deno.test("requireCaller: suspended admin -> 403 forbidden", async () => {
  await withUsers([{ role: "admin", status: "suspended" }], async ([u]) => {
    const e = await assertRejects(() => requireCaller(reqWith(u.token), ["admin", "owner"]), HttpError);
    assertEquals(e.status, 403);
    assertEquals(e.code, "forbidden");
  });
});

Deno.test("requireCaller: pending admin -> 403 forbidden", async () => {
  await withUsers([{ role: "admin", status: "pending" }], async ([u]) => {
    const e = await assertRejects(() => requireCaller(reqWith(u.token), ["admin"]), HttpError);
    assertEquals(e.code, "forbidden");
  });
});

Deno.test("requireCaller: active admin allowed -> {id, role}", async () => {
  await withUsers([{ role: "admin", status: "active" }], async ([u]) => {
    const c = await requireCaller(reqWith(u.token), ["admin", "owner"]);
    assertEquals(c, { id: u.id, role: "admin" });
  });
});

Deno.test("handle: HttpError -> status and body, with CORS", async () => {
  const h = handle(() => Promise.reject(new HttpError("conflict", 409, "Already handled")));
  const res = await h(new Request("http://localhost/fn", { method: "POST" }));
  assertEquals(res.status, 409);
  assertEquals(await res.json(), { error: { code: "conflict", message: "Already handled" } });
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*");
  assertEquals(res.headers.get("Content-Type"), "application/json");
});

Deno.test("handle: unknown error -> 500 internal, message not leaked", async () => {
  const orig = console.error;
  console.error = () => {};
  try {
    const h = handle(() => Promise.reject(new Error("secret db password hunter2")));
    const res = await h(new Request("http://localhost/fn", { method: "POST" }));
    assertEquals(res.status, 500);
    const text = await res.text();
    const body = JSON.parse(text);
    assertEquals(body.error.code, "internal");
    assert(!text.includes("hunter2"));
    assertNotEquals(body.error.message, "");
  } finally {
    console.error = orig;
  }
});

Deno.test("handle: success passes through and gains CORS headers", async () => {
  const h = handle(() => Promise.resolve(new Response("ok")));
  const res = await h(new Request("http://localhost/fn", { method: "POST" }));
  assertEquals(await res.text(), "ok");
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*");
});

Deno.test("handle: OPTIONS -> 204 with CORS headers, handler not called", async () => {
  let called = false;
  const h = handle(() => {
    called = true;
    return Promise.resolve(new Response("x"));
  });
  const res = await h(new Request("http://localhost/fn", { method: "OPTIONS" }));
  assertEquals(res.status, 204);
  assertEquals(called, false);
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*");
  assertEquals(
    res.headers.get("Access-Control-Allow-Headers"),
    "authorization, x-client-info, apikey, content-type",
  );
  assertEquals(res.headers.get("Access-Control-Allow-Methods"), "POST, OPTIONS");
});
