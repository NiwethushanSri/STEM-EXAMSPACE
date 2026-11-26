import type { Op } from "./marking-model";

export type SaveStatus =
  | "saved"
  | "saving"
  | "offline"
  | "stale"
  | "hold_expired"
  | "on_hold"
  | "pictures_updating"
  | "closed"
  | "reason_required"
  | "refused";
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

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null;
const isPoints = (v: unknown) =>
  v === undefined || (Array.isArray(v) && v.every((p) => Array.isArray(p) && p.length === 2 && p.every((n) => typeof n === "number")));

// A stored operation of a shape the server could take; anything else is dropped.
function isOp(v: unknown): v is Op {
  if (!isObj(v) || typeof v.op !== "string") return false;
  switch (v.op) {
    case "mark":
      return typeof v.question_id === "string" && (v.mark === null || typeof v.mark === "number") && typeof v.na === "boolean";
    case "ann_put":
      return (
        typeof v.id === "string" && typeof v.page_id === "string" && typeof v.kind === "string" &&
        typeof v.x === "number" && typeof v.y === "number" && isPoints(v.points) &&
        (v.text === undefined || typeof v.text === "string")
      );
    case "ann_del":
    case "ann_restore":
      return typeof v.id === "string";
    case "note":
      return typeof v.text === "string";
    default:
      return false;
  }
}

/** Operations written down but not yet saved, returned only when they follow the rev the server now holds. */
export function restorePending(markingId: string, rev: number, storage: Store | undefined = defaultStorage()): Op[] {
  try {
    const raw = storage?.getItem(keyFor(markingId));
    if (!raw) return [];
    const saved = JSON.parse(raw) as { rev?: unknown; ops?: unknown };
    return saved.rev === rev && Array.isArray(saved.ops) ? saved.ops.filter(isOp) : [];
  } catch {
    return [];
  }
}

// Only these refusals are the network or the session; everything else the server says no to will never be accepted.
const RETRY_CODES = new Set(["network", "server_error", "unauthenticated", "not_authenticated", "unauthorized"]);

const STOPS: Record<string, SaveStatus> = {
  hold_expired: "hold_expired",
  on_hold: "on_hold",
  pictures_updating: "pictures_updating",
  marking_closed: "closed",
  reason_required: "reason_required",
};

export type SaveQueue = {
  push(ops: Op[]): void;
  /** Sends everything now; resolves true when nothing is left unsaved. */
  flush(): Promise<boolean>;
  pending(): number;
  /** The reason a change after submit carries; later saves send it. Call resume() to try again. */
  setReason(reason: string): void;
  /** Starts sending again after a stop (a reason given, a fix made). */
  resume(): void;
  /** Drops the unsent operations and their stored copy (the marker chose to after a refusal). */
  discard(): void;
  /** 3B: drops the unsent operations and their stored copy and stays stopped, saying nothing: for a refusal the server
   * will never take back (the screen puts the last saved state back). Unlike discard, it never sends again and never
   * says "saved". */
  drop(): void;
  /** The code of the refusal that stopped the queue, or null. */
  lastRefusal(): string | null;
  /** Stops every timer (React cleanup). Unsent operations stay in storage. */
  dispose(): void;
};

const MAX_WAIT_MS = 5000;

/**
 * Sends the marker's operations to the server in order, one call at a time, at most 200 to a call. Nothing leaves the
 * queue until the server has accepted it. A network failure or server/session error retries (2, 4, 8, then every 15
 * seconds). A stale rev, a hold, or any other refusal stops the queue and keeps everything, in memory and in `storage`.
 */
export function createSaveQueue(opts: {
  markingId: string;
  rev: number;
  send: (rev: number, ops: Op[], activeSeconds: number, reason?: string) => Promise<SaveResult>;
  debounceMs?: number;
  storage?: Store;
  onStatus: (s: SaveStatus, code?: string) => void;
  /** 3B: each batch the server accepted, in order (also one discarded while it was on its way: the server has it). */
  onSaved?: (ops: Op[]) => void;
}): SaveQueue {
  const debounceMs = opts.debounceMs ?? 800;
  const storage = opts.storage ?? defaultStorage();
  let rev = opts.rev;
  const queue: Op[] = [];
  let timer: ReturnType<typeof setTimeout> | null = null;
  let retry: ReturnType<typeof setTimeout> | null = null;
  let running: Promise<void> | null = null;
  let stopped = false;
  let disposed = false;
  let epoch = 0;
  let failures = 0;
  let status: SaveStatus | null = null;
  let refusal: string | null = null;
  let reason: string | undefined;
  let activeMs = 0;
  let lastPush: number | null = null;
  let waitStart: number | null = null;

  const setStatus = (s: SaveStatus, code?: string) => {
    if (s === status && code === undefined) return;
    status = s;
    opts.onStatus(s, code);
  };

  const persist = () => {
    try {
      if (queue.length === 0) storage?.removeItem(keyFor(opts.markingId));
      else storage?.setItem(keyFor(opts.markingId), JSON.stringify({ rev, ops: queue }));
    } catch {
      // Storage may be full or blocked; the queue in memory still holds everything.
    }
  };

  const clearTimers = () => {
    if (timer) clearTimeout(timer);
    if (retry) clearTimeout(retry);
    timer = null;
    retry = null;
  };

  const backoff = () => {
    failures++;
    setStatus("offline");
    if (disposed) return;
    retry = setTimeout(() => {
      retry = null;
      void run();
    }, RETRY_MS[failures - 1] ?? RETRY_LATER_MS);
  };

  async function drain(): Promise<void> {
    while (queue.length > 0 && !stopped && !disposed) {
      const batch = queue.slice(0, BATCH);
      const seconds = Math.round(activeMs / 1000);
      const carried = activeMs;
      const mine = epoch;
      activeMs = 0;
      waitStart = null;
      setStatus("saving");
      let result: SaveResult;
      try {
        result = await opts.send(rev, batch, seconds, reason);
      } catch {
        if (mine === epoch) {
          activeMs += carried;
          backoff();
        }
        return;
      }
      if (result.ok) opts.onSaved?.(batch);
      if (mine !== epoch) continue; // discarded while in flight
      if (result.ok) {
        queue.splice(0, batch.length);
        rev = result.rev;
        failures = 0;
        persist();
        continue;
      }
      activeMs += carried;
      if (RETRY_CODES.has(result.code)) {
        backoff();
        return;
      }
      stopped = true;
      refusal = result.code;
      if (result.code === "conflict" && result.reason === "rev") setStatus("stale", result.code);
      else setStatus(STOPS[result.code] ?? "refused", result.code);
      return;
    }
    if (queue.length === 0 && !stopped && !disposed) setStatus("saved");
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
      if (stopped || disposed) return;
      setStatus("saving");
      if (retry) return; // the pending retry will carry these too
      // Debounce, but never wait longer than MAX_WAIT_MS from the first unsent change, so steady work still saves.
      if (waitStart === null) waitStart = now;
      if (timer) clearTimeout(timer);
      const delay = Math.max(0, Math.min(debounceMs, waitStart + MAX_WAIT_MS - now));
      timer = setTimeout(() => {
        timer = null;
        void run();
      }, delay);
    },
    async flush() {
      if (timer) clearTimeout(timer);
      timer = null;
      if (retry) clearTimeout(retry);
      retry = null;
      // A call may already be in flight; wait for it, then send whatever followed it.
      while (running) await running;
      await run();
      return queue.length === 0;
    },
    pending: () => queue.length,
    setReason(r) {
      reason = r;
    },
    resume() {
      if (disposed) return;
      stopped = false;
      refusal = null;
      failures = 0;
      clearTimers();
      if (queue.length === 0) setStatus("saved");
      else void run();
    },
    discard() {
      epoch++;
      queue.length = 0;
      clearTimers();
      persist();
      stopped = false;
      refusal = null;
      failures = 0;
      waitStart = null;
      setStatus("saved");
    },
    drop() {
      epoch++;
      queue.length = 0;
      clearTimers();
      persist();
      waitStart = null;
    },
    lastRefusal: () => refusal,
    dispose() {
      disposed = true;
      clearTimers();
    },
  };
}
