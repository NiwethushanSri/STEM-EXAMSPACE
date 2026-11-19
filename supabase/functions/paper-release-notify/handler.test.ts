import { assert, assertEquals } from "jsr:@std/assert@1";
import type { SupabaseClient } from "@supabase/supabase-js";
import { BUDGET_MS, type Deps, label, makeHandler, sameSecret } from "./handler.ts";

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
 * A small in-memory stand-in for the notice functions of migration 049: one notice per entry, its recipients,
 * who is marked, the lease, and the 15-minute wait / give-up after 3 runs where every send failed. The SQL itself
 * is tested in supabase/tests/026_paper_notices.test.sql; this checks how the handler drives it.
 */
function fakeDb(
  notices: { kind: "released" | "corrected"; who: { email: string; first_name: string | null }[] }[],
  clock: () => number,
) {
  const calls: string[] = [];
  const state = notices.map((n, i) => ({
    id: i + 1,
    kind: n.kind,
    exam_id: `e${i + 1}`,
    who: n.who.map((w, j) => ({ profile_id: `n${i + 1}-u${j}`, ...w })),
    marked: new Set<string>(),
    leased: false,
    failedRounds: 0,
    retryAt: 0,
    done: false,
    stopped: false,
  }));
  const left = (s: (typeof state)[number]) => s.who.filter((w) => !s.marked.has(w.profile_id));
  const rpc = (name: string, args: Record<string, unknown> = {}) => {
    calls.push(name);
    const s = state.find((x) => x.id === args.p_notice);
    switch (name) {
      case "paper_notice_open":
        return Promise.resolve({ data: 0, error: null });
      case "paper_notice_next": {
        const exclude = (args.p_exclude as number[]) ?? [];
        const n = state.find((x) => !x.done && !x.leased && x.retryAt <= clock() && !exclude.includes(x.id));
        if (!n) return Promise.resolve({ data: [], error: null });
        n.leased = true;
        return Promise.resolve({
          data: [{ notice_id: n.id, kind: n.kind, exam_id: n.exam_id, title: "GCSE Maths", paper: "Paper 1" }],
          error: null,
        });
      }
      case "paper_notice_recipients":
        return Promise.resolve({ data: left(s!), error: null });
      case "paper_notice_mark": {
        if (s!.done || s!.stopped) return Promise.resolve({ data: "stopped", error: null });
        const p = args.p_profile as string;
        if (s!.marked.has(p)) return Promise.resolve({ data: "already", error: null });
        s!.marked.add(p);
        return Promise.resolve({ data: "ok", error: null });
      }
      case "paper_notice_unmark":
        s!.marked.delete(args.p_profile as string);
        return Promise.resolve({ data: null, error: null });
      case "paper_notice_finish": {
        s!.leased = false;
        if (left(s!).length === 0) {
          s!.done = true;
          return Promise.resolve({ data: "done", error: null });
        }
        if (args.p_sent === 0 && (args.p_failed as number) > 0) {
          s!.failedRounds++;
          if (s!.failedRounds >= 3) {
            s!.done = true;
            return Promise.resolve({ data: "gave_up", error: null });
          }
          s!.retryAt = clock() + 15 * MIN;
          return Promise.resolve({ data: "retry", error: null });
        }
        return Promise.resolve({ data: "continue", error: null });
      }
    }
    return Promise.reject(new Error(`unexpected rpc ${name}`));
  };
  const svc = {
    rpc,
    from: () => {
      throw new Error("tables are never written directly");
    },
  };
  return { svc: svc as unknown as SupabaseClient, calls, state };
}

function deps(over: Partial<Deps> & { svc: Deps["svc"] }): Deps {
  const env: Record<string, string> = { CRON_SECRET: "s3cret", EMAIL_PROVIDER: "console" };
  return { env: (n) => env[n], send: () => Promise.resolve(true), now: () => 0, sleep: () => Promise.resolve(), ...over };
}
const req = (secret = "s3cret") =>
  new Request("http://x.test/", { method: "POST", headers: { "x-cron-secret": secret }, body: "{}" });
const people = (n: number) => Array.from({ length: n }, (_, i) => ({ email: `p${i}@example.test`, first_name: `P${i}` }));
const run = async (h: (r: Request) => Promise<Response>) => await (await h(req())).json();

Deno.test("sameSecret", () => {
  assert(sameSecret("abc", "abc"));
  assert(!sameSecret("abd", "abc"));
  assert(!sameSecret("ab", "abc"));
  assert(!sameSecret("abcd", "abc"));
  assert(!sameSecret(null, "abc"));
  assert(!sameSecret("", ""));
});

Deno.test("label does not repeat the paper", () => {
  assertEquals(label("GCSE Maths", "Paper 1"), "GCSE Maths Paper 1");
  assertEquals(label("GCSE Maths Paper 1", "Paper 1"), "GCSE Maths Paper 1");
});

Deno.test("wrong secret is 401 before anything else", async () => {
  const h = makeHandler(deps({ svc: never }));
  assertEquals((await h(req("nope"))).status, 401);
});

Deno.test("email off: skipped, zero database calls", async () => {
  await quiet(async () => {
    const h = makeHandler({
      ...deps({ svc: never }),
      env: (n) => (n === "CRON_SECRET" ? "s3cret" : undefined),
    });
    const res = await h(req());
    assertEquals(res.status, 200);
    const body = await res.json();
    assertEquals(body.skipped, true);
    assertEquals(body.released, []);
  });
});

Deno.test("everyone emailed in one run: done, and the next run sends nothing", async () => {
  await quiet(async () => {
    const db = fakeDb([{ kind: "released", who: people(3) }], () => 0);
    const sent: string[] = [];
    const h = makeHandler(deps({ svc: () => db.svc, send: (to) => (sent.push(to), Promise.resolve(true)) }));
    const o = (await run(h)).released[0];
    assertEquals([o.attempted, o.sent, o.failed, o.state, o.retry], [3, 3, 0, "done", false]);
    assertEquals((await run(h)).released, []);
    assertEquals(sent.length, 3);
  });
});

Deno.test("remainder across two ticks: the second run emails only who is left", async () => {
  await quiet(async () => {
    let clock = 0;
    const db = fakeDb([{ kind: "released", who: people(6) }], () => clock);
    const sent: string[] = [];
    const h = makeHandler(deps({
      svc: () => db.svc,
      now: () => clock,
      send: (to) => {
        sent.push(to);
        clock += BUDGET_MS / 2; // two sends use up a run's time budget
        return Promise.resolve(true);
      },
    }));
    const first = (await run(h)).released[0];
    assert(first.sent >= 1 && first.sent <= 3); // only sends already in flight finish
    assertEquals(first.state, "continue");
    assertEquals(first.retry, false);
    assertEquals(first.sent + first.unsent, 6);
    // The next tick (a minute later) carries on with the rest.
    const ticks = [first];
    for (let i = 0; i < 6 && !db.state[0].done; i++) {
      clock += MIN;
      ticks.push((await run(h)).released[0]);
    }
    assertEquals(ticks.at(-1)!.state, "done");
    assertEquals(ticks.reduce((a, t) => a + t.sent, 0), 6);
    assertEquals(sent.length, 6);
    assertEquals(new Set(sent).size, 6); // nobody twice
  });
});

Deno.test("partial failure: the failed address is tried again by a later run, the others are not", async () => {
  await quiet(async () => {
    let clock = 0;
    const db = fakeDb([{ kind: "released", who: people(3) }], () => clock);
    const sent: string[] = [];
    let n = 0;
    const h = makeHandler(deps({
      svc: () => db.svc,
      now: () => clock,
      send: (to) => {
        sent.push(to);
        return Promise.resolve(++n !== 2);
      },
    }));
    const first = (await run(h)).released[0];
    assertEquals([first.attempted, first.sent, first.failed, first.state, first.retry], [3, 2, 1, "continue", false]);
    clock += MIN;
    const second = (await run(h)).released[0];
    assertEquals([second.total, second.attempted, second.sent, second.state], [1, 1, 1, "done"]);
    assertEquals(sent.length, 4);
    assertEquals(sent[3], sent[1]); // only the address that failed
  });
});

Deno.test("total failure backs off 15 minutes, then gives up after the third failed run", async () => {
  await quiet(async () => {
    let clock = 0;
    const db = fakeDb([{ kind: "released", who: people(2) }], () => clock);
    let attempts = 0;
    const h = makeHandler(deps({
      svc: () => db.svc,
      now: () => clock,
      send: () => (attempts++, Promise.resolve(false)),
    }));
    const first = (await run(h)).released[0];
    assertEquals([first.attempted, first.sent, first.failed, first.state, first.retry], [2, 0, 2, "retry", true]);
    // Not every minute: the next 14 ticks do nothing.
    for (let i = 1; i < 15; i++) {
      clock = i * MIN;
      assertEquals((await run(h)).released, []);
    }
    assertEquals(attempts, 2);
    clock = 15 * MIN;
    assertEquals((await run(h)).released[0].state, "retry");
    clock = 30 * MIN;
    const third = (await run(h)).released[0];
    assertEquals([third.state, third.retry], ["gave_up", false]);
    clock = 60 * MIN;
    assertEquals((await run(h)).released, []);
    assertEquals(attempts, 6); // 3 runs of 2
    assertEquals(db.state[0].marked.size, 0); // failed sends are not recorded as sent
  });
});

Deno.test("a total failure of a corrected notice backs off too", async () => {
  await quiet(async () => {
    const db = fakeDb([{ kind: "corrected", who: people(2) }], () => 0);
    const h = makeHandler(deps({ svc: () => db.svc, send: () => Promise.resolve(false) }));
    const o = (await run(h)).corrected[0];
    assertEquals([o.state, o.retry], ["retry", true]);
  });
});

Deno.test("no recipients: done, nothing sent", async () => {
  await quiet(async () => {
    const db = fakeDb([{ kind: "released", who: [] }], () => 0);
    const h = makeHandler(deps({ svc: () => db.svc }));
    const o = (await run(h)).released[0];
    assertEquals([o.attempted, o.state, o.retry], [0, "done", false]);
  });
});

Deno.test("a duplicate address is emailed once", async () => {
  await quiet(async () => {
    const db = fakeDb([{
      kind: "released",
      who: [{ email: "Same@Example.test", first_name: "A" }, { email: "same@example.test", first_name: "B" }],
    }], () => 0);
    const sent: string[] = [];
    const h = makeHandler(deps({ svc: () => db.svc, send: (to) => (sent.push(to), Promise.resolve(true)) }));
    const o = (await run(h)).released[0];
    assertEquals(o.attempted, 1);
    assertEquals(sent.length, 1);
  });
});

Deno.test("every send is marked first, and a failed one is unmarked", async () => {
  await quiet(async () => {
    const db = fakeDb([{ kind: "released", who: people(2) }], () => 0);
    let n = 0;
    const order: string[] = [];
    const h = makeHandler(deps({
      svc: () => db.svc,
      send: () => {
        order.push(`send:${db.calls.at(-1)}`);
        return Promise.resolve(++n === 1);
      },
    }));
    await run(h);
    assert(order.every((o) => o === "send:paper_notice_mark"));
    assertEquals(db.calls.filter((c) => c === "paper_notice_unmark").length, 1);
  });
});

Deno.test("an address someone else already emailed is skipped", async () => {
  await quiet(async () => {
    const db = fakeDb([{ kind: "released", who: people(2) }], () => 0);
    db.state[0].marked.add("n1-u0");
    // recipients would no longer list it; force the race where it still does
    const sent: string[] = [];
    const svc = {
      rpc: (name: string, args: Record<string, unknown>) =>
        name === "paper_notice_recipients"
          ? Promise.resolve({ data: db.state[0].who, error: null })
          : (db.svc.rpc as unknown as (n: string, a: unknown) => Promise<unknown>)(name, args),
    } as unknown as SupabaseClient;
    const h = makeHandler(deps({ svc: () => svc, send: (to) => (sent.push(to), Promise.resolve(true)) }));
    const o = (await run(h)).released[0];
    assertEquals([o.attempted, o.sent], [1, 1]);
    assertEquals(sent, ["p1@example.test"]);
  });
});

Deno.test("a notice stopped mid-run (held) stops sending", async () => {
  await quiet(async () => {
    const db = fakeDb([{ kind: "released", who: people(5) }], () => 0);
    let n = 0;
    const h = makeHandler(deps({
      svc: () => db.svc,
      send: () => {
        if (++n === 2) db.state[0].stopped = true;
        return Promise.resolve(true);
      },
    }));
    const o = (await run(h)).released[0];
    assert(o.attempted <= 3);
    assertEquals(o.state, "continue");
  });
});

Deno.test("stops starting sends when the time budget is used up, and leaves the rest for the next run", async () => {
  await quiet(async () => {
    let clock = 0;
    const db = fakeDb([{ kind: "released", who: people(6) }], () => clock);
    const h = makeHandler(deps({
      svc: () => db.svc,
      now: () => clock,
      send: () => {
        clock += BUDGET_MS;
        return Promise.resolve(true);
      },
    }));
    const o = (await run(h)).released[0];
    assert(o.attempted >= 1 && o.attempted <= 2); // only sends already in flight
    assertEquals(o.attempted + o.unsent, 6);
    assertEquals([o.state, o.retry], ["continue", false]);
    assertEquals(db.state[0].marked.size, o.sent);
  });
});

Deno.test("several notices in one run, each worked once", async () => {
  await quiet(async () => {
    const db = fakeDb([{ kind: "released", who: people(2) }, { kind: "corrected", who: people(1) }], () => 0);
    let n = 0;
    const h = makeHandler(deps({ svc: () => db.svc, send: () => Promise.resolve(++n !== 1) }));
    const body = await run(h);
    assertEquals(body.released.length, 1); // the partly failed notice is not taken again in the same run
    assertEquals(body.released[0].state, "continue");
    assertEquals(body.corrected[0].state, "done");
  });
});

Deno.test("a lookup failure releases the notice without counting a failed run", async () => {
  await quiet(async () => {
    const db = fakeDb([{ kind: "released", who: people(2) }], () => 0);
    const svc = {
      rpc: (name: string, args: Record<string, unknown>) =>
        name === "paper_notice_recipients"
          ? Promise.resolve({ data: null, error: { code: "XX000" } })
          : (db.svc.rpc as unknown as (n: string, a: unknown) => Promise<unknown>)(name, args),
    } as unknown as SupabaseClient;
    let sends = 0;
    const h = makeHandler(deps({ svc: () => svc, send: () => (sends++, Promise.resolve(true)) }));
    const o = (await run(h)).released[0];
    assertEquals([o.attempted, o.state, sends], [0, "continue", 0]);
    assertEquals(db.state[0].failedRounds, 0);
  });
});
