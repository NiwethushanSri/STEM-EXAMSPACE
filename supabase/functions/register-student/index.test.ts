import { assert, assertEquals } from "jsr:@std/assert@1";
import { anon, createTestUser, deleteUserIds, deleteUsers, env, service } from "../_shared/test_helpers.ts";

const url = () => `${env("SUPABASE_URL")}/functions/v1/register-student`;
const svc = service();

// The deployed function may run with EMAIL_PROVIDER unset (fails closed), in which case a brand-new
// registration is created and then removed again. These tests therefore never rely on a sent email: where a
// sign-up must exist they create it the way the function does (no password), and links come from generateLink.

async function clearLimits() {
  const { error } = await svc.from("login_attempts").delete().or("key.like.reg:%,key.like.regx:%,key.like.rege:%");
  if (error) throw new Error(`limit cleanup failed: ${error.code}`);
}

function body(email: string, over: Record<string, unknown> = {}) {
  return {
    firstName: "Nimal",
    lastName: "Perera",
    email,
    dateOfBirth: "2012-03-04",
    school: "Royal College",
    parentName: "Kamal Perera",
    parentEmail: `parent-${crypto.randomUUID()}@example.test`,
    ...over,
  };
}

async function register(b: unknown): Promise<{ status: number; json: any; ms: number }> {
  // No Authorization header at all: the function is public.
  const t = performance.now();
  const res = await fetch(url(), { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(b) });
  const json = await res.json().catch(() => null);
  return { status: res.status, json, ms: performance.now() - t };
}

const uid = (tag: string) => `t17-${crypto.randomUUID()}-${tag}@example.test`;

async function userByEmail(email: string) {
  const { data } = await svc.from("profiles").select("id, status, role, first_name").eq("email", email.toLowerCase()).maybeSingle();
  return data as { id: string; status: string; role: string; first_name: string } | null;
}

async function signIn(email: string, password: string): Promise<boolean> {
  const { data, error } = await anon().auth.signInWithPassword({ email, password });
  return !error && !!data.session;
}

/** A self sign-up exactly as the function leaves it: unconfirmed, NO password. */
async function createSignup(email: string, parentEmail: string, first = "Victim") {
  const { data, error } = await svc.auth.admin.createUser({
    email,
    email_confirm: false,
    user_metadata: {
      first_name: first,
      last_name: "Student",
      date_of_birth: "2012-03-04",
      school: "Royal College",
      parent_name: "Parent",
      parent_email: parentEmail,
    },
  });
  if (error || !data.user) throw new Error(`createUser failed: ${error?.message}`);
  return data.user.id;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function withCleanup(fn: (track: (email: string) => string) => Promise<void>) {
  const emails: string[] = [];
  await clearLimits();
  try {
    await fn((e) => (emails.push(e), e));
  } finally {
    await sleep(4000); // the function finishes its work in the background after answering
    const ids: string[] = [];
    for (const e of emails) {
      const p = await userByEmail(e);
      if (p) ids.push(p.id);
    }
    await clearLimits();
    await deleteUserIds(svc, ids);
  }
}

Deno.test("register-student: no password is accepted or stored (sign-in impossible before the link)", async () => {
  await withCleanup(async (track) => {
    const email = track(uid("nopw"));
    // A password in the body is ignored: it is neither required nor used.
    const r = await register(body(email, { password: "Sent-By-Attacker-1" }));
    assertEquals(r.status, 200);
    assertEquals(r.json, { ok: true });
    assertEquals(await signIn(email, "Sent-By-Attacker-1"), false);
    const r2 = await register(body(track(uid("nopw2"))));
    assertEquals(r2.status, 200, "no password field is not an error");

    // The shape the function creates: no usable password.
    const e2 = track(uid("shape"));
    await createSignup(e2, "p@example.test");
    for (const guess of ["Sent-By-Attacker-1", "Password-A-1234", ""]) assertEquals(await signIn(e2, guess), false);
  });
});

Deno.test("register-student: a sign-up under 1 hour old is not replaced by another submitter", async () => {
  await withCleanup(async (track) => {
    const victim = track(uid("victim"));
    const victimParent = `victim-parent-${crypto.randomUUID()}@example.test`;
    const victimId = await createSignup(victim, victimParent);

    const a = await register(body(victim, { firstName: "Attacker", parentEmail: `attacker-${crypto.randomUUID()}@example.test` }));
    assertEquals(a.status, 200);
    assertEquals(a.json, { ok: true });
    await sleep(4000); // background work has finished

    const after = await userByEmail(victim);
    assertEquals(after?.id, victimId, "same account");
    assertEquals(after?.first_name, "Victim");
    const { data: det } = await svc.from("student_details").select("signup_parent_email").eq("profile_id", victimId).single();
    assertEquals(det?.signup_parent_email, victimParent);
  });
});

Deno.test("register-student: the inbox owner alone ends up with a password", async () => {
  await withCleanup(async (track) => {
    // The sign-up as the function creates it (no password, unconfirmed). Whoever controls the inbox completes
    // the recovery link and chooses the only password. (The 1-hour replacement rule is proven in pgTAP.)
    const victim = track(uid("late"));
    const realParent = `real-parent-${crypto.randomUUID()}@example.test`;
    const newId = await createSignup(victim, realParent, "Real");
    assertEquals(await signIn(victim, "Attacker-Guess-1"), false, "the attacker has no usable password");

    const { data: link, error: lErr } = await svc.auth.admin.generateLink({ type: "recovery", email: victim });
    assert(!lErr && link.properties?.hashed_token);
    const victimClient = anon();
    const { error: vErr } = await victimClient.auth.verifyOtp({ token_hash: link.properties.hashed_token, type: "recovery" });
    assertEquals(vErr, null);
    const { error: uErr } = await victimClient.auth.updateUser({ password: "Victim-Chosen-Pw-9" });
    assertEquals(uErr, null);

    assertEquals(await signIn(victim, "Attacker-Guess-1"), false);
    assertEquals(await signIn(victim, "Victim-Chosen-Pw-9"), true);
    const confirmed = await userByEmail(victim);
    assertEquals(confirmed?.id, newId);
    assertEquals(confirmed?.status, "pending", "the link confirms the email");
    const { data: det } = await svc.from("student_details").select("signup_parent_email").eq("profile_id", newId).single();
    assertEquals(det?.signup_parent_email, realParent);
  });
});

Deno.test("register-student: identical status and body, and at least 800 ms, for new / confirmed / staff / young sign-up", async () => {
  await withCleanup(async (track) => {
    const fresh = track(uid("new"));
    const confirmed = track(uid("confirmed"));
    const { data, error } = await svc.auth.admin.createUser({
      email: confirmed,
      password: "Original-Pass-1",
      email_confirm: true,
      user_metadata: { first_name: "Orig", last_name: "Inal" },
    });
    assert(!error && data.user);
    const staff = await createTestUser(svc, { role: "admin", status: "active" });
    const young = track(uid("young"));
    await createSignup(young, "p@example.test");
    try {
      const results = {
        fresh: await register(body(fresh)),
        confirmed: await register(body(confirmed, { firstName: "Intruder" })),
        staff: await register(body(staff.email)),
        young: await register(body(young)),
      };
      for (const [name, r] of Object.entries(results)) {
        assertEquals(r.status, 200, name);
        assertEquals(JSON.stringify(r.json), JSON.stringify({ ok: true }), name);
        assert(r.ms >= 790, `${name} answered in ${Math.round(r.ms)} ms`); // 800 ms floor minus client timer slack
      }
      await sleep(4000);
      const after = await userByEmail(confirmed);
      assertEquals(after?.first_name, "Orig");
      assertEquals(await signIn(confirmed, "Original-Pass-1"), true);
    } finally {
      await deleteUsers(svc, [staff]);
    }
  });
});

Deno.test("register-student: response time is the same for new / confirmed / protected requests", async () => {
  await withCleanup(async (track) => {
    const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
    const times: Record<string, number[]> = { new: [], confirmed: [], protected: [] };
    for (let i = 0; i < 3; i++) {
      times.new.push((await register(body(track(uid(`tnew${i}`))))).ms);

      const c = track(uid(`tconf${i}`));
      const { error } = await svc.auth.admin.createUser({ email: c, password: "Original-Pass-1", email_confirm: true });
      assertEquals(error, null);
      times.confirmed.push((await register(body(c))).ms);

      const y = track(uid(`tprot${i}`));
      await createSignup(y, "p@example.test");
      times.protected.push((await register(body(y))).ms);
    }
    const m = Object.fromEntries(Object.entries(times).map(([k, v]) => [k, median(v)]));
    console.log("median ms:", JSON.stringify(m));
    for (const [k, v] of Object.entries(m)) assert(v >= 790, `${k} median ${Math.round(v)} ms`);
    const vals = Object.values(m);
    assert(Math.max(...vals) - Math.min(...vals) <= 200, `medians differ by more than 200 ms: ${JSON.stringify(m)}`);
  });
});

Deno.test("register-student: staff (confirmed or not) are never touched", async () => {
  await withCleanup(async (track) => {
    const staff = await createTestUser(svc, { role: "tutor", status: "active" });
    try {
      track(staff.email);
      const r = await register(body(staff.email));
      assertEquals(r.status, 200);
      assertEquals(r.json, { ok: true });
      const p = await userByEmail(staff.email);
      assertEquals(p?.id, staff.id);
      assertEquals(p?.role, "tutor");
    } finally {
      await deleteUsers(svc, [staff]);
    }

    // An unconfirmed shell that is not a plain student sign-up (here: a tutor) is protected too.
    const email = track(uid("unconfirmed-tutor"));
    const { data, error } = await svc.auth.admin.createUser({ email, password: "Shell-Pass-1234", email_confirm: false });
    assert(!error && data.user);
    const { error: uErr } = await svc.from("profiles").update({ role: "tutor", status: "unconfirmed" }).eq("id", data.user.id);
    assertEquals(uErr, null);
    const r2 = await register(body(email));
    assertEquals(r2.status, 200);
    assertEquals(r2.json, { ok: true });
    await sleep(4000);
    const p2 = await userByEmail(email);
    assertEquals(p2?.id, data.user.id);
    assertEquals(p2?.role, "tutor");
  });
});

Deno.test("register-student: validation errors are 400 and create nothing", async () => {
  await withCleanup(async (track) => {
    const email = track(uid("invalid"));
    const cases: Record<string, unknown> = {
      "bad email": body("not-an-email"),
      "bad parent email": body(email, { parentEmail: "nope" }),
      "too young": body(email, { dateOfBirth: new Date(Date.now() - 5 * 365.25 * 864e5).toISOString().slice(0, 10) }),
      "too old": body(email, { dateOfBirth: "1990-01-01" }),
      "impossible date": body(email, { dateOfBirth: "2012-02-31" }),
      "empty name": body(email, { firstName: "   " }),
      "long school": body(email, { school: "s".repeat(121) }),
      "missing field": { email },
      "array body": [],
    };
    for (const [name, b] of Object.entries(cases)) {
      const r = await register(b);
      assertEquals(r.status, 400, name);
      assertEquals(r.json.error.code, "invalid_input", name);
    }
    assertEquals(await userByEmail(email), null);
  });
});

Deno.test("register-student: 4th attempt for one email in 15 minutes is 429", async () => {
  await withCleanup(async (track) => {
    const email = track(uid("emaillimit"));
    // A confirmed address is the cheapest valid attempt (no email, no account).
    const { data, error } = await svc.auth.admin.createUser({ email, password: "Original-Pass-1", email_confirm: true });
    assert(!error && data.user);
    for (let i = 0; i < 3; i++) assertEquals((await register(body(email))).status, 200, `attempt ${i + 1}`);
    const limited = await register(body(email.toUpperCase()));
    assertEquals(limited.status, 429, "the key is the lower-cased email");
    assertEquals(limited.json.error.code, "rate_limited");
    // Another address from the same IP is still fine.
    assertEquals((await register(body(track(uid("other"))))).status, 200);
  });
});

Deno.test("register-student: 31st attempt from one IP in 15 minutes is 429", async () => {
  await withCleanup(async (track) => {
    const confirmed = track(uid("iplimit"));
    const { data, error } = await svc.auth.admin.createUser({ email: confirmed, password: "Original-Pass-1", email_confirm: true });
    assert(!error && data.user);
    assertEquals((await register(body(confirmed))).status, 200);
    // Learn the key the function recorded for this caller, then fill it to 29 attempts in the window.
    const { data: rows, error: rErr } = await svc.from("login_attempts").select("key").like("key", "reg:%");
    assertEquals(rErr, null);
    assertEquals(rows!.length, 1);
    const ipKey = rows![0].key as string;
    const { error: iErr } = await svc.from("login_attempts").insert(Array.from({ length: 28 }, () => ({ key: ipKey })));
    assertEquals(iErr, null);
    // The 30th attempt passes, the 31st does not (different addresses, so the email limit is not what trips).
    assertEquals((await register(body(track(uid("ip30"))))).status, 200);
    const limited = await register(body(track(uid("ip31"))));
    assertEquals(limited.status, 429);
    assertEquals(limited.json.error.code, "rate_limited");
  });
});
