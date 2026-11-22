import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { _renderForTest, markingAlertLine, staffAlertLine } from "../_shared/email.ts";
import { dataFor, type Deps, makeHandler, type Notice } from "./handler.ts";

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

const MIN = 60_000;

/**
 * A stateful stand-in for the notice functions of migration 055: claim one due notice (a claimed one waits 5 minutes
 * times its attempts, 3 attempts at most), record and forget recipients, mark. The SQL itself is tested in
 * supabase/tests/032_script_notices.test.sql; this checks how the handler drives it.
 */
function fakeDb(notices: Notice[], clock: () => number = () => 0) {
  const marks: { id: number; ok: boolean }[] = [];
  const recorded = new Map<number, Set<string>>();
  const state = new Map(notices.map((n) => [n.id, { attempts: 0, claimedAt: -1, sent: false }]));
  const left = (n: Notice) => (n.recipients ?? []).filter((r) => !recorded.get(n.id)?.has(r.profile_id));
  const svc = {
    rpc: (name: string, args: Record<string, unknown> = {}) => {
      if (name === "script_notice_next") {
        // As the SQL hands them out (migrations 076 and 008): the families' notices first, then staff and marking alerts.
        const staff = (n: Notice) => n.kind === "staff_alert" || n.kind === "marking_alert";
        const ordered = [...notices.filter((n) => !staff(n)), ...notices.filter(staff)];
        for (const n of ordered) {
          const s = state.get(n.id)!;
          if (s.sent || s.attempts >= 3 || (s.claimedAt >= 0 && s.claimedAt > clock() - s.attempts * 5 * MIN)) continue;
          s.attempts++;
          s.claimedAt = clock();
          if (left(n).length === 0) {
            s.sent = true;
            continue;
          }
          return Promise.resolve({ data: [{ ...n, recipients: left(n) }], error: null });
        }
        return Promise.resolve({ data: [], error: null });
      }
      if (name === "script_notice_record") {
        const id = args.p_id as number, p = args.p_profile as string;
        if (state.get(id)!.sent) return Promise.resolve({ data: "stopped", error: null });
        const set = recorded.get(id) ?? new Set<string>();
        recorded.set(id, set);
        if (set.has(p)) return Promise.resolve({ data: "already", error: null });
        set.add(p);
        return Promise.resolve({ data: "ok", error: null });
      }
      if (name === "script_notice_unmark") {
        recorded.get(args.p_id as number)?.delete(args.p_profile as string);
        return Promise.resolve({ data: null, error: null });
      }
      if (name === "script_notice_mark") {
        marks.push({ id: args.p_id as number, ok: args.p_ok as boolean });
        if (args.p_ok) state.get(args.p_id as number)!.sent = true;
        return Promise.resolve({ data: null, error: null });
      }
      if (name === "script_notice_given_up") {
        const n = notices.filter((x) => !state.get(x.id)!.sent && state.get(x.id)!.attempts >= 3).length;
        return Promise.resolve({ data: n, error: null });
      }
      return Promise.reject(new Error(`unexpected rpc ${name}`));
    },
  };
  return { svc: svc as unknown as SupabaseClient, marks, recorded, state };
}

const deps = (over: Partial<Deps> & { svc: Deps["svc"] }): Deps => {
  const env: Record<string, string> = { CRON_SECRET: "s3cret", EMAIL_PROVIDER: "console" };
  return { env: (n) => env[n], send: () => Promise.resolve(true), now: () => 0, sleep: () => Promise.resolve(), ...over };
};
const req = (secret = "s3cret") =>
  new Request("http://x.test/", { method: "POST", headers: { "x-cron-secret": secret }, body: "{}" });
const sink = () => {
  const to: string[] = [];
  return { to, send: (addr: string) => (to.push(addr), Promise.resolve(true)) };
};

const receipt: Notice = {
  id: 1,
  kind: "receipt",
  recipients: [
    { profile_id: "u-s", email: "student@example.test", first_name: "Zanzibar" },
    { profile_id: "u-p", email: "parent@example.test", first_name: "Pat" },
  ],
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
  recipients: [{ profile_id: "u-o", email: "owner@example.test", first_name: "Olga" }],
  exam: "GCSE Maths Paper 1",
  script_number: "S-ABC-0001",
  submission_seq: null,
  at: null,
  page_count: null,
  pages: null,
  exception_kind: "late",
};

const markingAlert: Notice = {
  id: 7,
  kind: "marking_alert",
  recipients: [
    { profile_id: "u-l", email: "lead@example.test", first_name: "Lena" },
    { profile_id: "u-a", email: "admin@example.test", first_name: "Ada" },
  ],
  exam: "GCSE Maths Paper 1",
  script_number: "S-ABC-0002",
  submission_seq: null,
  at: "2031-06-09T09:00:00Z",
  page_count: 3,
  pages: [1, 2, 3],
  exception_kind: null,
  count: 1,
  alert_kind: "picture_changed",
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
    assertEquals(body, { notices: 1, sent: 2, failed: 0, given_up: 0 });
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
    assertEquals(Object.keys(sent[0].data).sort(), ["count", "exam", "kind", "script_number"]);
    assertEquals(sent[0].data.count, "1");
    const mail = _renderForTest("script_staff_alert", { ...sent[0].data, name: "Zanzibar Smith", student_name: "Zanzibar Smith" });
    assert(!mail.html.includes("Zanzibar") && !mail.subject.includes("Zanzibar"));
    assert(mail.html.includes("GCSE Maths Paper 1") && mail.html.includes("Handed in late") && mail.html.includes("S-ABC-0001"));
  });
});

Deno.test("family notices are sent before staff alerts, and an alert says how many pages it is about", async () => {
  await quiet(async () => {
    // Queued first: an alert about 12 pages of one file. The family's receipt still goes out before it.
    const many: Notice = { ...alert, id: 5, exception_kind: "not_expected", script_number: null, count: 12 };
    const db = fakeDb([many, receipt]);
    const sent: { to: string; template: string; data: Record<string, string> }[] = [];
    const h = makeHandler(deps({
      svc: () => db.svc,
      send: (to, template, data) => (sent.push({ to, template, data }), Promise.resolve(true)),
    }));
    const body = await (await h(req())).json();
    assertEquals(body, { notices: 2, sent: 3, failed: 0, given_up: 0 });
    assertEquals(sent.map((s) => s.template), ["script_receipt", "script_receipt", "script_staff_alert"]);
    assertEquals(db.marks, [{ id: 1, ok: true }, { id: 5, ok: true }]);

    const d = sent[2].data;
    assertEquals([d.kind, d.count], ["not_expected", "12"]);
    const mail = _renderForTest("script_staff_alert", d);
    assert(mail.html.includes("12 pages of one file were not expected for this exam."), mail.html);
    assert(!mail.html.includes("Script:")); // an email about many pages names no one script
  });
});

Deno.test("the count wording of each kind of staff alert", () => {
  assertEquals(staffAlertLine("not_expected", 1), "1 page of one file was not expected for this exam.");
  assertEquals(staffAlertLine("not_expected", 50), "50 pages of one file were not expected for this exam.");
  assertEquals(staffAlertLine("other_exam", 3), "3 pages of one file belong to another exam.");
  assertEquals(staffAlertLine("uncoded_family_page", 2), "2 pages without a code are in a family's hand-in.");
  assertEquals(staffAlertLine("processing_failed", 4), "A file could not be processed.");
  assertEquals(staffAlertLine("late", 1), "1 script was handed in late.");
  assertEquals(staffAlertLine("late", 7), "7 scripts were handed in late.");
  assertEquals(staffAlertLine("needs_attention", 1), "1 home script needs attention.");
  assertEquals(staffAlertLine("needs_attention", 5), "5 home scripts need attention.");
  assertEquals(staffAlertLine("something_else", 0), "A script needs staff attention.");
  const one = _renderForTest("script_staff_alert", { exam: "GCSE Maths", kind: "late", count: "1", script_number: "S-ABC-0001" });
  assert(one.html.includes("1 script was handed in late.") && one.html.includes("Script: S-ABC-0001") && one.html.includes("Handed in late"));
  const old = _renderForTest("script_staff_alert", { exam: "GCSE Maths", kind: "late", script_number: "S-ABC-0001" });
  assert(old.html.includes("1 script was handed in late.")); // a notice with no count is about one
});

Deno.test("one of several recipients failing: only that one is retried", async () => {
  await quiet(async () => {
    let clock = 0;
    const db = fakeDb([receipt], () => clock);
    const to: string[] = [];
    let failStudent = true;
    const h = makeHandler(deps({
      svc: () => db.svc,
      send: (addr) => {
        if (addr.startsWith("student") && failStudent) return Promise.resolve(false);
        to.push(addr);
        return Promise.resolve(true);
      },
    }));
    const first = await (await h(req())).json();
    assertEquals([first.sent, first.failed], [1, 1]);
    assertEquals(db.marks, [{ id: 1, ok: false }]);
    failStudent = false;
    clock += 6 * MIN;
    await h(req());
    assertEquals(to, ["parent@example.test", "student@example.test"]); // the parent got it once
    assertEquals(db.marks.at(-1), { id: 1, ok: true });
  });
});

Deno.test("a crash after sending some: those are not emailed again", async () => {
  await quiet(async () => {
    const db = fakeDb([receipt]);
    db.recorded.set(1, new Set(["u-s"])); // the student was recorded (and emailed) by a run that died before marking
    const s = sink();
    const h = makeHandler(deps({ svc: () => db.svc, send: s.send }));
    await h(req());
    assertEquals(s.to, ["parent@example.test"]);
    assertEquals(db.marks, [{ id: 1, ok: true }]);
  });
});

Deno.test("a failed mark: the next run emails nobody again", async () => {
  await quiet(async () => {
    let clock = 0;
    const db = fakeDb([receipt], () => clock);
    const real = db.svc.rpc.bind(db.svc);
    let breakMark = true;
    const svc = {
      rpc: (name: string, args?: Record<string, unknown>) =>
        name === "script_notice_mark" && breakMark ? Promise.resolve({ data: null, error: { code: "XX000" } }) : real(name, args),
    } as unknown as SupabaseClient;
    const s = sink();
    const h = makeHandler(deps({ svc: () => svc, send: s.send }));
    await h(req());
    breakMark = false;
    clock += 6 * MIN;
    await h(req());
    assertEquals(s.to.length, 2); // both once, never twice
    assert(db.state.get(1)!.sent); // the second run found everyone recorded and finished the notice
  });
});

Deno.test("budget cut-off: no notice is claimed once time is up, and no attempt is burnt", async () => {
  await quiet(async () => {
    let clock = 0;
    const db = fakeDb([receipt, { ...alert, id: 3 }], () => clock);
    const s = sink();
    const h = makeHandler(deps({
      svc: () => db.svc,
      now: () => clock,
      send: (a) => {
        clock += 200_000; // the first send uses the whole budget
        return s.send(a);
      },
    }));
    const body = await (await h(req())).json();
    assertEquals(body.notices, 1);
    assertEquals(db.state.get(3)!.attempts, 0); // never claimed
    assertEquals(db.marks, [{ id: 1, ok: false }]); // cut short: the rest of its people wait for the next run
    clock += 6 * MIN;
    await h(req());
    assertEquals(s.to.filter((a) => a === "student@example.test").length, 1);
    assertEquals(s.to.filter((a) => a === "parent@example.test").length, 1);
  });
});

Deno.test("two overlapping runs: nobody is emailed twice", async () => {
  await quiet(async () => {
    const db = fakeDb([receipt]);
    // Both runs got the notice (the second claimed it before the first marked anyone): the record decides.
    const run = () => {
      let handed = false; // each run is handed the notice once
      return {
        rpc: (name: string, args?: Record<string, unknown>) => {
          if (name !== "script_notice_next") return db.svc.rpc(name, args);
          const data = handed ? [] : [receipt];
          handed = true;
          return Promise.resolve({ data, error: null });
        },
      } as unknown as SupabaseClient;
    };
    const s = sink();
    const slow = () => new Promise<void>((r) => setTimeout(r, 1));
    const hA = makeHandler(deps({ svc: run, send: s.send, sleep: slow }));
    const hB = makeHandler(deps({ svc: run, send: s.send, sleep: slow }));
    const [a, b] = await Promise.all([hA(req()), hB(req())]);
    await a.body?.cancel();
    await b.body?.cancel();
    assertEquals(s.to.slice().sort(), ["parent@example.test", "student@example.test"]);
  });
});

Deno.test("notices given up after 3 attempts are counted in the result", async () => {
  await quiet(async () => {
    let clock = 0;
    const db = fakeDb([receipt], () => clock);
    const h = makeHandler(deps({ svc: () => db.svc, send: () => Promise.resolve(false) }));
    let body = await (await h(req())).json();
    for (let i = 0; i < 2; i++) {
      clock += 11 * MIN;
      body = await (await h(req())).json();
    }
    assertEquals(body.given_up, 1);
  });
});

Deno.test("marking_alert_goes_to_lead_and_admins", async () => {
  await quiet(async () => {
    // The database lists the subject's lead marker and the active owner and admin accounts (migration 008).
    const db = fakeDb([markingAlert, receipt]);
    const sent: { to: string; template: string; data: Record<string, string> }[] = [];
    const h = makeHandler(deps({
      svc: () => db.svc,
      send: (to, template, data) => (sent.push({ to, template, data }), Promise.resolve(true)),
    }));
    const body = await (await h(req())).json();
    assertEquals(body, { notices: 2, sent: 4, failed: 0, given_up: 0 });
    // The family's receipt still goes first; then the marking alert, to each of its people once.
    assertEquals(sent.map((s) => s.template), ["script_receipt", "script_receipt", "script_marking_alert", "script_marking_alert"]);
    assertEquals(sent.slice(2).map((s) => s.to), ["lead@example.test", "admin@example.test"]);
    assertEquals(db.marks, [{ id: 1, ok: true }, { id: 7, ok: true }]);
    assertEquals(sent[2].data, { exam: "GCSE Maths Paper 1", script_number: "S-ABC-0002", kind: "picture_changed" });
  });
});

Deno.test("marking_alert_email_has_no_candidate_or_marker_name", () => {
  const data = dataFor(markingAlert, "Lena");
  assertEquals(Object.keys(data).sort(), ["exam", "kind", "script_number"]); // no name of anyone, not even the recipient's
  // Even when it is handed names by mistake, the email shows none of them.
  for (const kind of ["picture_changed", "picture_missing", "name_visible", "pages_set_aside", "pages_changed"]) {
    const mail = _renderForTest("script_marking_alert", {
      ...data, kind, name: "Zanzibar Smith", student_name: "Zanzibar Smith", marker_name: "Mara One", first_name: "Lena",
    });
    for (const n of ["Zanzibar", "Smith", "Mara", "Lena"]) assert(!mail.html.includes(n) && !mail.subject.includes(n), `${kind}: ${n}`);
    assert(mail.html.includes("GCSE Maths Paper 1") && mail.html.includes("S-ABC-0002"), kind);
    assert(mail.html.includes(markingAlertLine(kind)), kind);
  }
});

Deno.test("the sentence of each kind of marking alert", () => {
  assertEquals(
    markingAlertLine("picture_changed"),
    "A page picture of this script changed during marking. The script is on hold until you release it.",
  );
  assertEquals(markingAlertLine("name_visible"), "A marker reported a visible name. Staff must hide it and hand the script back.");
  assertEquals(markingAlertLine("pages_set_aside"), "Scanned pages arrived for a script that is being marked. They were set aside.");
  assertEquals(
    markingAlertLine("pages_changed"),
    "The pages of a script changed while it was with staff. Its marker has been asked to check their marks.",
  );
  assertEquals(
    markingAlertLine("picture_missing"),
    "A page of this script lost its marking picture during marking. The script is on hold until an admin takes it back.",
  );
  assertEquals(markingAlertLine("something_else"), "A script being marked needs attention.");
  const mail = _renderForTest("script_marking_alert", { exam: "GCSE Maths", kind: "name_visible", script_number: "S-ABC-0002" });
  assert(mail.subject.includes("GCSE Maths"), mail.subject);
  assert(mail.html.includes("Script: S-ABC-0002"), mail.html);
});
