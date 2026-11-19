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

/** A minimal stand-in for the service client that records every call. */
function fakeSvc(who: { email: string; first_name: string | null }[], kind: "release" | "corrected" = "release") {
  const calls: string[] = [];
  const q = {
    update(v: unknown) {
      calls.push(`update:${JSON.stringify(v)}`);
      return q;
    },
    eq(col: string, val: unknown) {
      calls.push(`eq:${col}=${val}`);
      return q;
    },
    is: () => q,
    in: () => q,
    select: () => Promise.resolve({ data: [{ id: "p1" }], error: null }),
    then: (res: (v: unknown) => void) => res({ error: null }),
  };
  const svc = {
    from: (t: string) => {
      calls.push(`from:${t}`);
      return q;
    },
    rpc: (name: string) => {
      calls.push(`rpc:${name}`);
      if (name === "paper_release_due") {
        return Promise.resolve({
          data: kind === "release" ? [{ exam_id: "e1", title: "GCSE Maths", paper: "Paper 1" }] : [],
          error: null,
        });
      }
      if (name === "paper_corrected_due") {
        return Promise.resolve({
          data: kind === "corrected"
            ? [{ exam_id: "e1", title: "GCSE Maths", paper: "Paper 1", paper_ids: ["p1"] }]
            : [],
          error: null,
        });
      }
      return Promise.resolve({ data: who, error: null });
    },
  };
  return { svc: svc as unknown as SupabaseClient, calls };
}

function deps(over: Partial<Deps> & { svc: Deps["svc"] }): Deps {
  const env: Record<string, string> = { CRON_SECRET: "s3cret", EMAIL_PROVIDER: "console" };
  return { env: (n) => env[n], send: () => Promise.resolve(true), now: () => 0, sleep: () => Promise.resolve(), ...over };
}
const req = (secret = "s3cret") =>
  new Request("http://x.test/", { method: "POST", headers: { "x-cron-secret": secret }, body: "{}" });
const people = (n: number) => Array.from({ length: n }, (_, i) => ({ email: `p${i}@example.test`, first_name: `P${i}` }));

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

Deno.test("partial failure is counted and not rolled back", async () => {
  await quiet(async () => {
    const { svc, calls } = fakeSvc(people(3));
    let n = 0;
    const h = makeHandler(deps({ svc: () => svc, send: () => Promise.resolve(++n !== 2) }));
    const o = (await (await h(req())).json()).released[0];
    assertEquals([o.attempted, o.sent, o.failed, o.retry], [3, 2, 1, false]);
    assert(!calls.some((c) => c.includes('"release_notified_at":null')));
  });
});

Deno.test("total failure rolls the claim back", async () => {
  await quiet(async () => {
    const { svc, calls } = fakeSvc(people(3));
    const h = makeHandler(deps({ svc: () => svc, send: () => Promise.resolve(false) }));
    const o = (await (await h(req())).json()).released[0];
    assertEquals([o.attempted, o.sent, o.failed, o.retry], [3, 0, 3, true]);
    assert(calls.some((c) => c.includes('"release_notified_at":null')));
  });
});

Deno.test("total failure of a corrected notice rolls back corrected_notified_at", async () => {
  await quiet(async () => {
    const { svc, calls } = fakeSvc(people(2), "corrected");
    const h = makeHandler(deps({ svc: () => svc, send: () => Promise.resolve(false) }));
    const o = (await (await h(req())).json()).corrected[0];
    assertEquals(o.retry, true);
    assert(calls.some((c) => c.includes('"corrected_notified_at":null')));
  });
});

Deno.test("no recipients: claimed, nothing to retry", async () => {
  await quiet(async () => {
    const { svc, calls } = fakeSvc([]);
    const h = makeHandler(deps({ svc: () => svc }));
    const o = (await (await h(req())).json()).released[0];
    assertEquals([o.attempted, o.retry], [0, false]);
    assert(!calls.some((c) => c.includes('"release_notified_at":null')));
  });
});

Deno.test("a duplicate address is emailed once", async () => {
  await quiet(async () => {
    const { svc } = fakeSvc([
      { email: "Same@Example.test", first_name: "A" },
      { email: "same@example.test", first_name: "B" },
    ]);
    const sent: string[] = [];
    const h = makeHandler(deps({ svc: () => svc, send: (to) => (sent.push(to), Promise.resolve(true)) }));
    const o = (await (await h(req())).json()).released[0];
    assertEquals(o.attempted, 1);
    assertEquals(sent.length, 1);
  });
});

Deno.test("stops starting sends when the time budget is used up", async () => {
  await quiet(async () => {
    const { svc } = fakeSvc(people(6));
    let clock = 0;
    const h = makeHandler(deps({
      svc: () => svc,
      now: () => clock,
      send: () => {
        clock += BUDGET_MS;
        return Promise.resolve(true);
      },
    }));
    const o = (await (await h(req())).json()).released[0];
    assert(o.attempted >= 1 && o.attempted <= 2); // only sends already in flight
    assertEquals(o.attempted + o.unsent, 6);
    assertEquals(o.retry, false);
  });
});

Deno.test("rollback only while the row still holds this run's claim", async () => {
  await quiet(async () => {
    const { svc, calls } = fakeSvc(people(2));
    const h = makeHandler(deps({ svc: () => svc, send: () => Promise.resolve(false) }));
    await (await h(req())).json();
    const claimed = new Date(0).toISOString();
    const i = calls.findIndex((c) => c.includes('"release_notified_at":null'));
    assert(i >= 0);
    assert(calls.slice(i + 1, i + 4).includes("eq:release_notified_at=" + claimed));
  });
  await quiet(async () => {
    const { svc, calls } = fakeSvc(people(2), "corrected");
    const h = makeHandler(deps({ svc: () => svc, send: () => Promise.resolve(false) }));
    await (await h(req())).json();
    const i = calls.findIndex((c) => c.includes('"corrected_notified_at":null'));
    assert(i >= 0);
    assert(calls.slice(i + 1, i + 4).includes("eq:corrected_notified_at=" + new Date(0).toISOString()));
  });
});

Deno.test("time runs out after the claim but before any send: claim rolled back", async () => {
  await quiet(async () => {
    const { svc, calls } = fakeSvc(people(3));
    let n = 0;
    const h = makeHandler(deps({ svc: () => svc, now: () => (++n <= 3 ? 0 : BUDGET_MS) }));
    const o = (await (await h(req())).json()).released[0];
    assertEquals([o.attempted, o.sent, o.unsent, o.retry], [0, 0, 3, true]);
    assert(calls.some((c) => c.includes('"release_notified_at":null')));
  });
});
