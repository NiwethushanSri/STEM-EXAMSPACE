import type { Op } from "./marking-model";

export type SaveStatus = "saved" | "saving" | "offline" | "stale" | "hold_expired" | "on_hold" | "pictures_updating" | "closed";
export type SaveResult = { ok: true; rev: number } | { ok: false; code: string; reason?: string; rev?: number };

type Store = Pick<Storage, "getItem" | "setItem" | "removeItem">;

const BATCH = 200;
const IDLE_CAP_MS = 30_000;
const RETRY_MS = [2000, 4000, 8000];
const RETRY_LATER_MS = 15_000;
const keyFor = (markingId: string) => `stem-marking-pending-${markingId}`;

function defaultStorage(): Store | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

/** Operations written down but not yet saved, returned only when they follow the rev the server now holds. */
export function restorePending(markingId: string, rev: number, storage: Store | undefined = defaultStorage()): Op[] {
  try {
    const raw = storage?.getItem(keyFor(markingId));
    if (!raw) return [];
    const saved = JSON.parse(raw) as { rev?: unknown; ops?: unknown };
    return saved.rev === rev && Array.isArray(saved.ops) ? (saved.ops as Op[]) : [];
  } catch {
    return [];
  }
}

const STOPS: Record<string, SaveStatus> = {
  hold_expired: "hold_expired",
  on_hold: "on_hold",
  pictures_updating: "pictures_updating",
  marking_closed: "closed",
};

/**
 * Sends the marker's operations to the server in order, one call at a time, at most 200 to a call. Nothing leaves the
 * queue until the server has accepted it. A network failure retries (2, 4, 8, then every 15 seconds); a stale rev or a
 * refusal that needs a person stops the queue and keeps everything, in memory and in `storage`.
 */
export function createSaveQueue(opts: {
  markingId: string;
  rev: number;
  send: (rev: number, ops: Op[], activeSeconds: number) => Promise<SaveResult>;
  debounceMs?: number;
  storage?: Store;
  onStatus: (s: SaveStatus) => void;
}): { push(ops: Op[]): void; flush(): Promise<void>; pending(): number } {
  const debounceMs = opts.debounceMs ?? 800;
  const storage = opts.storage ?? defaultStorage();
  let rev = opts.rev;
  const queue: Op[] = [];
  let timer: ReturnType<typeof setTimeout> | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
  let running: Promise<void> | null = null;
  let stopped = false;
  let failures = 0;
  let status: SaveStatus | null = null;
  let activeMs = 0;
  let lastPush: number | null = null;

  const setStatus = (s: SaveStatus) => {
    if (s === status) return;
    status = s;
    opts.onStatus(s);
  };

  const persist = () => {
    try {
      if (queue.length === 0) storage?.removeItem(keyFor(opts.markingId));
      else storage?.setItem(keyFor(opts.markingId), JSON.stringify({ rev, ops: queue }));
    } catch {
      // Storage may be full or blocked; the queue in memory still holds everything.
    }
  };

  async function drain(): Promise<void> {
    while (queue.length > 0 && !stopped) {
      const batch = queue.slice(0, BATCH);
      const seconds = Math.round(activeMs / 1000);
      const carried = activeMs;
      activeMs = 0;
      setStatus("saving");
      let result: SaveResult;
      try {
        result = await opts.send(rev, batch, seconds);
      } catch {
        activeMs += carried;
        failures++;
        setStatus("offline");
        const wait = RETRY_MS[failures - 1] ?? RETRY_LATER_MS;
        retry = setTimeout(() => {
          retry = null;
          void run();
        }, wait);
        return;
      }
      if (result.ok) {
        queue.splice(0, batch.length);
        rev = result.rev;
        failures = 0;
        persist();
        continue;
      }
      activeMs += carried;
      if (result.code === "conflict" && result.reason === "rev") {
        stopped = true;
        setStatus("stale");
        return;
      }
      const stop = STOPS[result.code];
      if (stop) {
        stopped = true;
        setStatus(stop);
        return;
      }
      // Any other refusal: keep everything and try again later rather than drop an operation.
      failures++;
      setStatus("offline");
      retry = setTimeout(() => {
        retry = null;
        void run();
      }, RETRY_MS[failures - 1] ?? RETRY_LATER_MS);
      return;
    }
    if (queue.length === 0 && !stopped) setStatus("saved");
  }

  function run(): Promise<void> {
    if (running) return running;
    running = drain().finally(() => {
      running = null;
    });
    return running;
  }

  return {
    push(ops) {
      if (ops.length === 0) return;
      const now = Date.now();
      if (lastPush !== null) activeMs += Math.min(now - lastPush, IDLE_CAP_MS);
      lastPush = now;
      queue.push(...ops);
      persist();
      if (stopped) return;
      setStatus("saving");
      if (retry) return; // the pending retry will carry these too
      if (timer) clearTimeout(timer);
      timer = setTimeout(() => {
        timer = null;
        void run();
      }, debounceMs);
    },
    async flush() {
      if (timer) clearTimeout(timer);
      timer = null;
      if (retry) clearTimeout(retry);
      retry = null;
      // A call may already be in flight; wait for it, then send whatever followed it.
      while (running) await running;
      await run();
    },
    pending: () => queue.length,
  };
}
