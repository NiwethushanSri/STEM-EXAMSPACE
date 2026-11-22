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

function setup(send: (rev: number, ops: Op[], seconds: number) => Promise<SaveResult>, rev = 5) {
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
