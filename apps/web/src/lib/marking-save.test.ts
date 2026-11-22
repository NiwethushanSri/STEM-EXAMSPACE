import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Op } from "./marking-model";
import { createSaveQueue, restorePending, type SaveResult, type SaveStatus } from "./marking-save";

const note = (i: number): Op => ({ op: "note", text: `n${i}` });
const makeStorage = () => {
  const m = new Map<string, string>();
  return {
    m,
    getItem: (k: string) => m.get(k) ?? null,
    setItem: (k: string, v: string) => void m.set(k, v),
    removeItem: (k: string) => void m.delete(k),
  };
};

beforeEach(() => vi.useFakeTimers());
afterEach(() => vi.useRealTimers());

function setup(send: (rev: number, ops: Op[], seconds: number, reason?: string) => Promise<SaveResult>, rev = 5) {
  const storage = makeStorage();
  const statuses: SaveStatus[] = [];
  const q = createSaveQueue({ markingId: "m1", rev, send, storage, onStatus: (s) => statuses.push(s) });
  return { q, storage, statuses };
}

describe("save queue", () => {
  it("queue_batches_200_and_keeps_order", async () => {
    const calls: { rev: number; ops: Op[] }[] = [];
    let inflight = 0;
    let maxInflight = 0;
    const { q, statuses } = setup(async (rev, ops) => {
      inflight++;
      maxInflight = Math.max(maxInflight, inflight);
      calls.push({ rev, ops });
      await Promise.resolve();
      inflight--;
      return { ok: true, rev: rev + 1 };
    });
    q.push(Array.from({ length: 450 }, (_, i) => note(i)));
    expect(q.pending()).toBe(450);
    await vi.advanceTimersByTimeAsync(799);
    expect(calls.length).toBe(0);
    await vi.advanceTimersByTimeAsync(1);
    await q.flush();
    expect(calls.map((c) => c.ops.length)).toEqual([200, 200, 50]);
    expect(calls.map((c) => c.rev)).toEqual([5, 6, 7]);
    expect(calls.flatMap((c) => c.ops)).toEqual(Array.from({ length: 450 }, (_, i) => note(i)));
    expect(maxInflight).toBe(1);
    expect(q.pending()).toBe(0);
    expect(statuses[0]).toBe("saving");
    expect(statuses.at(-1)).toBe("saved");
  });

  it("pushes made while a call is in flight go behind it and nothing is lost", async () => {
    const calls: Op[][] = [];
    let release: (r: SaveResult) => void = () => {};
    const { q } = setup((_rev, ops) => {
      calls.push(ops);
      return new Promise<SaveResult>((r) => (release = r));
    });
    q.push([note(1)]);
    const done = q.flush();
    q.push([note(2)]);
    expect(q.pending()).toBe(2);
    release({ ok: true, rev: 6 });
    await vi.advanceTimersByTimeAsync(0);
    expect(calls.length).toBe(2);
    release({ ok: true, rev: 7 });
    await done;
    expect(calls).toEqual([[note(1)], [note(2)]]);
    expect(q.pending()).toBe(0);
  });

  it("queue_retries_when_offline_and_loses_nothing", async () => {
    let fail = true;
    let attempts = 0;
    const { q, storage, statuses } = setup(async (rev) => {
      attempts++;
      if (fail) throw new Error("network");
      return { ok: true, rev: rev + 1 };
    });
    q.push([note(1), note(2)]);
    await vi.advanceTimersByTimeAsync(800);
    expect(attempts).toBe(1);
    expect(statuses.at(-1)).toBe("offline");
    expect(q.pending()).toBe(2);
    expect(JSON.parse(storage.m.get("stem-marking-pending-m1")!)).toEqual({ rev: 5, ops: [note(1), note(2)] });
    q.push([note(3)]);
    await vi.advanceTimersByTimeAsync(1999);
    expect(attempts).toBe(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(attempts).toBe(2);
    await vi.advanceTimersByTimeAsync(4000);
    expect(attempts).toBe(3);
    await vi.advanceTimersByTimeAsync(8000);
    expect(attempts).toBe(4);
    await vi.advanceTimersByTimeAsync(15000);
    expect(attempts).toBe(5);
    await vi.advanceTimersByTimeAsync(15000);
    expect(attempts).toBe(6);
    expect(q.pending()).toBe(3);
    fail = false;
    await vi.advanceTimersByTimeAsync(15000);
    expect(q.pending()).toBe(0);
    expect(statuses.at(-1)).toBe("saved");
    expect(storage.m.has("stem-marking-pending-m1")).toBe(false);
  });

  it("a retry sends the earlier operations first, in order", async () => {
    const seen: Op[][] = [];
    let n = 0;
    const { q } = setup(async (rev, ops) => {
      seen.push(ops);
      if (n++ === 0) throw new Error("x");
      return { ok: true, rev: rev + 1 };
    });
    q.push([note(1)]);
    await vi.advanceTimersByTimeAsync(800);
    q.push([note(2)]);
    await vi.advanceTimersByTimeAsync(2000);
    expect(seen).toEqual([[note(1)], [note(1), note(2)]]);
  });

  it("queue_stops_on_stale_rev", async () => {
    let calls = 0;
    const { q, statuses, storage } = setup(async () => {
      calls++;
      return { ok: false, code: "conflict", reason: "rev", rev: 9 };
    });
    q.push([note(1)]);
    await vi.advanceTimersByTimeAsync(800);
    expect(calls).toBe(1);
    expect(statuses.at(-1)).toBe("stale");
    q.push([note(2)]);
    await vi.advanceTimersByTimeAsync(60000);
    expect(calls).toBe(1);
    expect(q.pending()).toBe(2);
    expect(JSON.parse(storage.m.get("stem-marking-pending-m1")!).ops).toEqual([note(1), note(2)]);
  });

  it("holds and closing stop sending and keep the operations", async () => {
    const cases: [string, SaveStatus][] = [
      ["hold_expired", "hold_expired"],
      ["on_hold", "on_hold"],
      ["pictures_updating", "pictures_updating"],
      ["marking_closed", "closed"],
    ];
    for (const [code, status] of cases) {
      let calls = 0;
      const { q, statuses } = setup(async () => {
        calls++;
        return { ok: false, code };
      });
      q.push([note(1)]);
      await vi.advanceTimersByTimeAsync(800);
      await vi.advanceTimersByTimeAsync(60000);
      expect(calls).toBe(1);
      expect(statuses.at(-1)).toBe(status);
      expect(q.pending()).toBe(1);
    }
  });

  it("every refusal the server will never accept stops the queue with the right status", async () => {
    const cases: { code: string; reason?: string; status: SaveStatus }[] = [
      { code: "invalid_input", status: "refused" },
      { code: "mark_out_of_range", status: "refused" },
      { code: "incomplete", status: "refused" },
      { code: "reason_required", status: "reason_required" },
      { code: "forbidden", status: "refused" },
      { code: "conflict", reason: "set_aside", status: "refused" },
      { code: "conflict", reason: "rev", status: "stale" },
    ];
    for (const c of cases) {
      let calls = 0;
      const { q, statuses } = setup(async () => {
        calls++;
        return { ok: false, code: c.code, reason: c.reason };
      });
      q.push([note(1)]);
      await vi.advanceTimersByTimeAsync(800);
      await vi.advanceTimersByTimeAsync(60000);
      expect(calls, c.code).toBe(1);
      expect(statuses.at(-1), c.code).toBe(c.status);
      expect(q.lastRefusal()).toBe(c.code);
      expect(q.pending()).toBe(1);
    }
  });

  it("a server or session error still retries", async () => {
    let calls = 0;
    const { q } = setup(async (rev) => (++calls < 2 ? { ok: false, code: "server_error" } : { ok: true, rev: rev + 1 }));
    q.push([note(1)]);
    await vi.advanceTimersByTimeAsync(800 + 2000);
    expect(calls).toBe(2);
    expect(q.pending()).toBe(0);
  });

  it("setReason then resume sends with the reason", async () => {
    const reasons: (string | undefined)[] = [];
    const { q, statuses } = setup(async (rev, _ops, _s, reason) => {
      reasons.push(reason);
      return reason ? { ok: true, rev: rev + 1 } : { ok: false, code: "reason_required" };
    });
    q.push([note(1)]);
    await vi.advanceTimersByTimeAsync(800);
    expect(statuses.at(-1)).toBe("reason_required");
    q.setReason("Mistake in 2(b)");
    q.resume();
    await vi.advanceTimersByTimeAsync(0);
    expect(reasons).toEqual([undefined, "Mistake in 2(b)"]);
    expect(q.pending()).toBe(0);
    expect(statuses.at(-1)).toBe("saved");
  });

  it("discard clears the queue and its storage", async () => {
    const { q, storage, statuses } = setup(async () => ({ ok: false, code: "invalid_input" }));
    q.push([note(1), note(2)]);
    await vi.advanceTimersByTimeAsync(800);
    expect(storage.m.has("stem-marking-pending-m1")).toBe(true);
    q.discard();
    expect(q.pending()).toBe(0);
    expect(storage.m.has("stem-marking-pending-m1")).toBe(false);
    expect(q.lastRefusal()).toBeNull();
    expect(statuses.at(-1)).toBe("saved");
  });

  it("flush resolves to whether everything saved", async () => {
    const ok = setup(async (rev) => ({ ok: true, rev: rev + 1 }));
    ok.q.push([note(1)]);
    expect(await ok.q.flush()).toBe(true);
    const bad = setup(async () => ({ ok: false, code: "invalid_input" }));
    bad.q.push([note(1)]);
    expect(await bad.q.flush()).toBe(false);
  });

  it("continuous pushes still save within 5 seconds", async () => {
    let sent = 0;
    const { q } = setup(async (rev, ops) => {
      sent += ops.length;
      return { ok: true, rev: rev + 1 };
    });
    for (let i = 0; i < 12; i++) {
      q.push([note(i)]);
      await vi.advanceTimersByTimeAsync(500);
    }
    expect(sent).toBeGreaterThanOrEqual(10);
  });

  it("dispose stops the timers", async () => {
    let calls = 0;
    const { q } = setup(async (rev) => (calls++, { ok: true, rev }));
    q.push([note(1)]);
    q.dispose();
    await vi.advanceTimersByTimeAsync(60000);
    expect(calls).toBe(0);
    expect(q.pending()).toBe(1);
  });

  it("restorePending drops malformed ops", () => {
    const { storage } = setup(async (rev) => ({ ok: true, rev }));
    storage.m.set(
      "stem-marking-pending-m1",
      JSON.stringify({ rev: 5, ops: [note(1), { op: "mark" }, null, { op: "nope" }, { op: "ann_del", id: "a" }, { op: "ann_put", id: "a" }] }),
    );
    expect(restorePending("m1", 5, storage)).toEqual([note(1), { op: "ann_del", id: "a" }]);
  });

  it("pending_ops_survive_reload_only_for_the_same_rev", async () => {
    const { storage } = setup(async () => {
      throw new Error("offline");
    });
    storage.m.set("stem-marking-pending-m1", JSON.stringify({ rev: 5, ops: [note(1), note(2)] }));
    expect(restorePending("m1", 5, storage)).toEqual([note(1), note(2)]);
    expect(restorePending("m1", 6, storage)).toEqual([]);
    expect(restorePending("other", 5, storage)).toEqual([]);
    storage.m.set("stem-marking-pending-m1", "not json");
    expect(restorePending("m1", 5, storage)).toEqual([]);
  });

  it("writes unsent operations with the rev they follow, and takes the server's rev after a save", async () => {
    const { q, storage } = setup(async (rev) => ({ ok: true, rev: rev + 3 }));
    q.push([note(1)]);
    expect(JSON.parse(storage.m.get("stem-marking-pending-m1")!)).toEqual({ rev: 5, ops: [note(1)] });
    await q.flush();
    expect(storage.m.has("stem-marking-pending-m1")).toBe(false);
    const revs: number[] = [];
    const again = setup(async (rev) => {
      revs.push(rev);
      return { ok: true, rev: rev + 3 };
    });
    again.q.push([note(1)]);
    await again.q.flush();
    again.q.push([note(2)]);
    await again.q.flush();
    expect(revs).toEqual([5, 8]);
  });

  it("flush with nothing queued resolves", async () => {
    const { q } = setup(async (rev) => ({ ok: true, rev }));
    await q.flush();
    expect(q.pending()).toBe(0);
  });
});
