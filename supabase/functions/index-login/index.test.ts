import { assert, assertEquals } from "jsr:@std/assert@1";
import { deleteUserIds, env, service } from "../_shared/test_helpers.ts";

const url = () => `${env("SUPABASE_URL")}/functions/v1/index-login`;

async function call(body: unknown, ip: string): Promise<{ status: number; text: string; json: any }> {
  const res = await fetch(url(), {
    method: "POST",
    headers: { apikey: env("SUPABASE_ANON_KEY"), "Content-Type": "application/json", "x-forwarded-for": ip },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json: any = null;
  try { json = JSON.parse(text); } catch { /* not json */ }
  return { status: res.status, text, json };
}

const rnd = () => String(Math.floor(100000 + Math.random() * 900000));
const uniqIp = () => `203.0.113.9-${crypto.randomUUID()}`;

async function withStudent(fn: (ctx: {
  svc: ReturnType<typeof service>;
  userId: string;
  email: string;
  password: string;
  index: string;
  ip: string;
}) => Promise<void>) {
  const svc = service();
  const ip = uniqIp();
  const index = `SE-2099-${rnd()}`;
  const keys = [`ip:${ip}`, `idx:${index}`, "idx:SE-2099-000000"];
  let userId: string | null = null;
  // The hosted gateway sets the first x-forwarded-for value to the real client IP, so a test cannot
  // pick its own ip key. Clear the shared ip rows before and after each scenario instead.
  const clearIp = async () => {
    const { error } = await svc.from("login_attempts").delete().like("key", "ip:%");
    if (error) throw new Error(`ip cleanup: ${error.message}`);
  };
  await clearIp();
  try {
    const email = `t9-${crypto.randomUUID()}@example.test`;
    const password = `Pw-${crypto.randomUUID()}`;
    const { data, error } = await svc.auth.admin.createUser({ email, password, email_confirm: true });
    if (error || !data.user) throw new Error("createUser failed");
    userId = data.user.id;
    const r1 = await svc.from("profiles").update({ role: "student", status: "active" }).eq("id", userId);
    if (r1.error) throw new Error(r1.error.message);
    const r2 = await svc.from("student_details").update({ index_number: index }).eq("profile_id", userId);
    if (r2.error) throw new Error(r2.error.message);
    await fn({ svc, userId, email, password, index, ip });
  } finally {
    const errs: string[] = [];
    const { error } = await svc.from("login_attempts").delete().in("key", keys);
    if (error) errs.push(`attempts cleanup: ${error.message}`);
    try { await clearIp(); } catch (e) { errs.push(String(e)); }
    if (userId) try { await deleteUserIds(svc, [userId]); } catch (e) { errs.push(String(e)); }
    if (errs.length) throw new Error(errs.join("; "));
  }
}

Deno.test("index-login: correct credentials -> tokens only, token works", async () => {
  await withStudent(async ({ svc, userId, email, password, index, ip }) => {
    const r = await call({ indexNumber: index, password }, ip);
    assertEquals(r.status, 200);
    assertEquals(Object.keys(r.json).sort(), ["access_token", "expires_in", "refresh_token"]);
    assert(!r.text.includes(email));
    const { data, error } = await svc.auth.getUser(r.json.access_token);
    assert(!error);
    assertEquals(data.user?.id, userId);
  });
});

Deno.test("index-login: wrong password and unknown index give identical 401", async () => {
  await withStudent(async ({ password, index, ip }) => {
    const a = await call({ indexNumber: index, password: password + "x" }, ip);
    const b = await call({ indexNumber: "SE-2099-000000", password }, ip);
    assertEquals(a.status, 401);
    assertEquals(b.status, 401);
    assertEquals(a.text, b.text);
    assertEquals(a.json, { error: { code: "invalid_credentials", message: "Index number or password is incorrect." } });
  });
});

Deno.test("index_login_normalises_input", async () => {
  await withStudent(async ({ password, index, ip }) => {
    const r1 = await call({ indexNumber: index.toLowerCase().replace(/-/g, " "), password }, ip);
    assertEquals(r1.status, 200);
    const r2 = await call({ indexNumber: index.replace(/-/g, ""), password }, ip);
    assertEquals(r2.status, 200);
  });
});

Deno.test("index-login: 6th attempt after 5 failures -> 429 even with correct password", async () => {
  await withStudent(async ({ password, index, ip }) => {
    for (let i = 0; i < 5; i++) {
      const r = await call({ indexNumber: index, password: "wrong" }, ip);
      assertEquals(r.status, 401);
    }
    const r = await call({ indexNumber: index, password }, ip);
    assertEquals(r.status, 429);
    assertEquals(r.json.error.code, "rate_limited");
    assertEquals(r.json.error.message, "Too many attempts. Try again later.");
  });
});

Deno.test("index-login: success clears the index counter", async () => {
  await withStudent(async ({ svc, password, index, ip }) => {
    for (let i = 0; i < 3; i++) await call({ indexNumber: index, password: "wrong" }, ip);
    const ok = await call({ indexNumber: index, password }, ip);
    assertEquals(ok.status, 200);
    const { count } = await svc.from("login_attempts").select("key", { count: "exact", head: true }).eq("key", `idx:${index}`);
    assertEquals(count, 0);
  });
});

Deno.test("index-login: bad body -> 400", async () => {
  const ip = uniqIp();
  const bodies = [
    {},
    { indexNumber: "SE-2099-123456" },
    { indexNumber: "", password: "x" },
    { indexNumber: 5, password: "x" },
    { indexNumber: "x".repeat(41), password: "x" },
    { indexNumber: "SE-2099-123456", password: "x".repeat(201) },
  ];
  for (const body of bodies) {
    const r = await call(body, ip);
    assertEquals(r.status, 400);
    assertEquals(r.json.error.code, "invalid_input");
  }
});
