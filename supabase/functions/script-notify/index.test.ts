import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { _renderForTest } from "../_shared/email.ts";
import { type Deps, makeHandler, type Notice } from "./handler.ts";

const quiet = async (fn: () => Promise<void>) => {
  const l = console.log, e = console.error;
  console.log = () => {};
  console.error = () => {};
  try {
    await fn();
  } finally {
    console.log = l;
    console.error = e;
  }
};

const never = (): SupabaseClient => {
  throw new Error("must not be called");
};

/** A stand-in for script_notice_next and script_notice_mark: hands out the notices once, records the marks. */
function fakeDb(notices: Notice[]) {
  const marks: { id: number; ok: boolean }[] = [];
  let handed = false;
  const svc = {
    rpc: (name: string, args: Record<string, unknown> = {}) => {
      if (name === "script_notice_next") {
        const data = handed ? [] : notices;
        handed = true;
        return Promise.resolve({ data, error: null });
      }
      if (name === "script_notice_mark") {
        marks.push({ id: args.p_id as number, ok: args.p_ok as boolean });
        return Promise.resolve({ data: null, error: null });
      }
      return Promise.reject(new Error(`unexpected rpc ${name}`));
    },
  };
  return { svc: svc as unknown as SupabaseClient, marks };
}

const deps = (over: Partial<Deps> & { svc: Deps["svc"] }): Deps => {
  const env: Record<string, string> = { CRON_SECRET: "s3cret", EMAIL_PROVIDER: "console" };
  return { env: (n) => env[n], send: () => Promise.resolve(true), now: () => 0, sleep: () => Promise.resolve(), ...over };
};
const req = (secret = "s3cret") =>
  new Request("http://x.test/", { method: "POST", headers: { "x-cron-secret": secret }, body: "{}" });

const receipt: Notice = {
  id: 1,
  kind: "receipt",
  recipients: [{ email: "student@example.test", first_name: "Zanzibar" }, { email: "parent@example.test", first_name: "Pat" }],
  exam: "GCSE Maths Paper 1",
  script_number: "S-ABC-0001",
  submission_seq: 2,
  at: "2031-06-07T09:45:00Z",
  page_count: 3,
  pages: [2, 3, 4],
  exception_kind: null,
};
const alert: Notice = {
  id: 2,
  kind: "staff_alert",
  recipients: [{ email: "owner@example.test", first_name: "Olga" }],
  exam: "GCSE Maths Paper 1",
  script_number: "S-ABC-0001",
  submission_seq: null,
  at: null,
  page_count: null,
  pages: null,
  exception_kind: "late",
};

Deno.test("handler_rejects_wrong_secret", async () => {
  const h = makeHandler(deps({ svc: never }));
  assertEquals((await h(req("nope"))).status, 401);
  assertEquals((await h(new Request("http://x.test/", { method: "POST", body: "{}" }))).status, 401);
  assertEquals((await h(new Request("http://x.test/", { method: "GET" }))).status, 405);
});

Deno.test("email_off_sends_and_marks_nothing", async () => {
  await quiet(async () => {
    const h = makeHandler({ ...deps({ svc: never }), env: (n) => (n === "CRON_SECRET" ? "s3cret" : undefined) });
    const res = await h(req());
    assertEquals(res.status, 200);
    assertEquals((await res.json()).skipped, true); // svc (every database call) was never touched
  });
});

Deno.test("receipt_goes_to_student_and_linked_parents", async () => {
  await quiet(async () => {
    const db = fakeDb([receipt]);
    const sent: { to: string; template: string; data: Record<string, string> }[] = [];
    const h = makeHandler(deps({
      svc: () => db.svc,
      send: (to, template, data) => (sent.push({ to, template, data }), Promise.resolve(true)),
    }));
    const body = await (await h(req())).json();
    assertEquals(body, { notices: 1, sent: 2, failed: 0 });
    assertEquals(sent.map((s) => s.to), ["student@example.test", "parent@example.test"]);
    assert(sent.every((s) => s.template === "script_receipt"));
    assertEquals(db.marks, [{ id: 1, ok: true }]);

    const d = sent[0].data;
    assertEquals([d.name, d.seq, d.page_count, d.pages, d.script_number], ["Zanzibar", "2", "3", "2, 3, 4", "S-ABC-0001"]);
    assertEquals(d.time, "7 June 2031 at 10:45"); // 09:45 UTC is 10:45 in London in June
    const mail = _renderForTest("script_receipt", d);
    assert(mail.html.includes("We have received your answers"));
    for (const part of ["GCSE Maths Paper 1", "S-ABC-0001", "10:45", "2, 3, 4"]) assert(mail.html.includes(part), part);
  });
});

Deno.test("a failed send marks the notice failed so the database retries it", async () => {
  await quiet(async () => {
    const db = fakeDb([receipt, alert]);
    let n = 0;
    const h = makeHandler(deps({ svc: () => db.svc, send: () => Promise.resolve(++n !== 2) }));
    const body = await (await h(req())).json();
    assertEquals([body.sent, body.failed], [2, 1]);
    assertEquals(db.marks, [{ id: 1, ok: false }, { id: 2, ok: true }]);
  });
});

Deno.test("staff_alert_has_no_candidate_name", async () => {
  await quiet(async () => {
    const db = fakeDb([alert]);
    const sent: { template: string; data: Record<string, string> }[] = [];
    const h = makeHandler(deps({
      svc: () => db.svc,
      send: (_to, template, data) => (sent.push({ template, data }), Promise.resolve(true)),
    }));
    await h(req());
    assertEquals(sent.length, 1);
    assertEquals(sent[0].template, "script_staff_alert");
    assertEquals(Object.keys(sent[0].data).sort(), ["exam", "kind", "script_number"]);
    const mail = _renderForTest("script_staff_alert", { ...sent[0].data, name: "Zanzibar Smith", student_name: "Zanzibar Smith" });
    assert(!mail.html.includes("Zanzibar") && !mail.subject.includes("Zanzibar"));
    assert(mail.html.includes("GCSE Maths Paper 1") && mail.html.includes("Handed in late") && mail.html.includes("S-ABC-0001"));
  });
});
