// Emails the families of home bookings when their exam's paper is released, and once when a paper they downloaded
// is replaced. The database decides everything (migration 049): which notices are due, who each one is for, who
// has already been emailed, and when a notice is retried or given up. This function only sends.
//
// Rules:
// - Without EMAIL_PROVIDER nothing is sent and nothing is marked, so turning email on later cannot announce old
//   releases.
// - paper_notice_open opens a notice for each release or replacement that is due. paper_notice_next hands out one
//   notice at a time, leased to this run, so overlapping runs never work the same notice.
// - Each recipient is marked (paper_notice_mark) before the email is sent, and unmarked again if the send fails:
//   at most one email per person and notice, and a failed one can be tried again by a later run.
// - No new send starts after BUDGET_MS. Whoever is left is emailed by the next run (every minute), so a large exam
//   takes several runs instead of losing its remainder.
// - paper_notice_finish ends the run's work on a notice: done when nobody is left; when every send of the run
//   failed (for example a missing key or the provider down) it waits 15 minutes, and gives up after 3 such runs.
// Logs hold counts, states and error codes only, never an address or a name.
import type { SupabaseClient } from "@supabase/supabase-js";
import { errorResponse, jsonResponse } from "../_shared/errors.ts";

export const MAX_PARALLEL = 2;
/** Each worker waits this long after a send: 2 workers at 1 s is about 2 requests a second. */
export const PACE_MS = 1000;
/** Stop starting sends after this long (the Edge Function wall-clock limit is higher). */
export const BUDGET_MS = 100_000;

export interface Recipient {
  profile_id: string;
  email: string;
  first_name: string | null;
}
/** What paper_notice_finish decided. */
export type NoticeState = "done" | "continue" | "retry" | "gave_up" | "unknown";
export interface Outcome {
  exam_id: string;
  attempted: number;
  sent: number;
  failed: number;
  /** People this notice still had to reach when this run took it. */
  total: number;
  /** Left for a later run (time ran out, a mark failed, or the notice was stopped). */
  unsent: number;
  /** True when every attempt failed: the notice waits before it is tried again. */
  retry: boolean;
  state: NoticeState;
}

export interface Deps {
  env: (name: string) => string | undefined;
  svc: () => SupabaseClient;
  send: (to: string, template: "paper_released" | "paper_corrected", data: Record<string, string>) => Promise<boolean>;
  now: () => number;
  sleep: (ms: number) => Promise<void>;
}

interface Notice {
  notice_id: number;
  kind: "released" | "corrected";
  exam_id: string;
  title: string;
  paper: string | null;
}

/** Compares without leaking where the first difference is. */
export function sameSecret(given: string | null, expected: string): boolean {
  if (!expected) return false;
  const enc = new TextEncoder();
  const a = enc.encode(given ?? "");
  const b = enc.encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) diff |= (a[i] ?? 0) ^ b[i];
  return diff === 0;
}

/** "GCSE Maths Paper 1": the exam title and its paper, without repeating the paper if the title has it. */
export function label(title: string, paper: string | null): string {
  const p = (paper ?? "").trim();
  return p && !title.toLowerCase().includes(p.toLowerCase()) ? `${title} ${p}` : title;
}

const STATES: readonly NoticeState[] = ["done", "continue", "retry", "gave_up"];

export function makeHandler(deps: Deps): (req: Request) => Promise<Response> {
  return async (req) => {
    if (req.method !== "POST") return errorResponse("invalid_input", "Use POST.", 405);
    if (!sameSecret(req.headers.get("x-cron-secret"), deps.env("CRON_SECRET") ?? "")) {
      return errorResponse("unauthenticated", "Not allowed.", 401);
    }
    await req.body?.cancel();

    const released: Outcome[] = [];
    const corrected: Outcome[] = [];
    if (!deps.env("EMAIL_PROVIDER")) {
      console.error("[paper-release-notify] email is off: nothing sent, nothing marked");
      return jsonResponse({ skipped: true, released, corrected });
    }

    const started = deps.now();
    const outOfTime = () => deps.now() - started >= BUDGET_MS;
    const svc = deps.svc();
    let failures = 0;

    /** Marks, sends and (on failure) unmarks each distinct address, MAX_PARALLEL at a time, paced. */
    async function sendAll(n: Notice, recipients: Recipient[]): Promise<Omit<Outcome, "exam_id" | "retry" | "state">> {
      const template = n.kind === "released" ? "paper_released" : "paper_corrected";
      const exam = label(n.title, n.paper);
      const seen = new Set<string>();
      const queue = recipients.filter((r) => {
        const k = r.email.toLowerCase();
        if (seen.has(k)) return false;
        seen.add(k);
        return true;
      });
      let next = 0, attempted = 0, sent = 0, failed = 0, stopped = false;
      const worker = async () => {
        while (next < queue.length && !stopped && !outOfTime()) {
          const r = queue[next++];
          const mark = await svc.rpc("paper_notice_mark", { p_notice: n.notice_id, p_profile: r.profile_id });
          if (mark.error) {
            console.error(`[paper-release-notify] mark failed code=${mark.error.code ?? "unknown"}`);
            failures++;
            continue; // never send without a mark; a later run tries again
          }
          if (mark.data === "stopped") {
            stopped = true;
            break;
          }
          if (mark.data !== "ok") continue; // already emailed
          attempted++;
          let ok = false;
          try {
            ok = await deps.send(r.email, template, { name: r.first_name ?? "there", exam });
          } catch {
            ok = false;
          }
          if (ok) sent++;
          else {
            failed++;
            const un = await svc.rpc("paper_notice_unmark", { p_notice: n.notice_id, p_profile: r.profile_id });
            if (un.error) failures++;
          }
          if (next < queue.length) await deps.sleep(PACE_MS);
        }
      };
      await Promise.all(Array.from({ length: Math.min(MAX_PARALLEL, queue.length) }, worker));
      return { total: queue.length, attempted, sent, failed, unsent: queue.length - attempted };
    }

    const opened = await svc.rpc("paper_notice_open");
    if (opened.error) {
      console.error(`[paper-release-notify] open failed code=${opened.error.code ?? "unknown"}`);
      failures++;
    }

    const worked: number[] = [];
    while (!outOfTime()) {
      const next = await svc.rpc("paper_notice_next", { p_exclude: worked });
      if (next.error) {
        console.error(`[paper-release-notify] next failed code=${next.error.code ?? "unknown"}`);
        failures++;
        break;
      }
      const n = ((next.data ?? []) as Notice[])[0];
      if (!n) break;
      worked.push(n.notice_id);

      const who = await svc.rpc("paper_notice_recipients", { p_notice: n.notice_id });
      let r: Omit<Outcome, "exam_id" | "retry" | "state">;
      if (who.error) {
        // Nothing was tried: the lease is released and the next run tries again (no failure is counted).
        console.error(`[paper-release-notify] recipients failed code=${who.error.code ?? "unknown"}`);
        failures++;
        r = { total: 0, attempted: 0, sent: 0, failed: 0, unsent: 0 };
      } else {
        r = await sendAll(n, (who.data ?? []) as Recipient[]);
      }

      const fin = await svc.rpc("paper_notice_finish", { p_notice: n.notice_id, p_sent: r.sent, p_failed: r.failed });
      if (fin.error) {
        console.error(`[paper-release-notify] finish failed code=${fin.error.code ?? "unknown"}`);
        failures++;
      }
      const state: NoticeState = STATES.includes(fin.data as NoticeState) ? fin.data as NoticeState : "unknown";
      const o: Outcome = { exam_id: n.exam_id, ...r, retry: state === "retry", state };
      (n.kind === "released" ? released : corrected).push(o);
      console.log(
        `[paper-release-notify] ${n.kind} attempted=${o.attempted} sent=${o.sent} failed=${o.failed} unsent=${o.unsent} state=${o.state}`,
      );
    }

    console.log(
      `[paper-release-notify] opened=${opened.data ?? 0} released_notices=${released.length} corrected_notices=${corrected.length} failures=${failures}`,
    );
    return jsonResponse({ released, corrected });
  };
}
