// Emails the families of home bookings when their exam's paper is released, and once when a paper they downloaded
// is replaced. The database chooses what is due and who gets it (paper_release_due and friends, all bounded by a
// 6-hour window).
//
// Rules:
// - Without EMAIL_PROVIDER nothing is sent and nothing is marked, so turning email on later cannot announce old
//   releases.
// - An exam (or paper version) is claimed, by setting its notified column, before sending so overlapping runs
//   cannot send twice. Sending is at most MAX_PARALLEL at a time, paced to stay under the provider's rate limit.
// - If nothing was sent (every attempt failed, for example a missing key, or the time ran out first) the claim is
//   rolled back so the next tick retries, but only while the row still holds this run's own claim value (a
//   reschedule or a newer run may have replaced it). A partial send is not retried: at-most-once per family.
// - No new send starts after BUDGET_MS; the unsent rest is left unsent (at-most-once) rather than overrunning the
//   function's time limit.
// Logs hold counts and error codes only, never an address or a name.
import type { SupabaseClient } from "@supabase/supabase-js";
import { errorResponse, jsonResponse } from "../_shared/errors.ts";

export const MAX_PARALLEL = 2;
/** Each worker waits this long after a send: 2 workers at 1 s is about 2 requests a second. */
export const PACE_MS = 1000;
/** Stop starting sends after this long (the Edge Function wall-clock limit is higher). */
export const BUDGET_MS = 100_000;

export interface Recipient {
  email: string;
  first_name: string | null;
}
export interface Outcome {
  exam_id: string;
  attempted: number;
  sent: number;
  failed: number;
  /** Distinct addresses to email. */
  total: number;
  /** Left unsent because the time budget ran out. */
  unsent: number;
  /** True when every attempt failed and the claim was rolled back for a retry. */
  retry: boolean;
}

export interface Deps {
  env: (name: string) => string | undefined;
  svc: () => SupabaseClient;
  send: (to: string, template: "paper_released" | "paper_corrected", data: Record<string, string>) => Promise<boolean>;
  now: () => number;
  sleep: (ms: number) => Promise<void>;
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

    /** Sends to each distinct address, MAX_PARALLEL at a time, paced; stops starting sends when out of time. */
    async function sendAll(
      recipients: Recipient[],
      template: "paper_released" | "paper_corrected",
      exam: string,
    ): Promise<Omit<Outcome, "exam_id" | "retry">> {
      const seen = new Set<string>();
      const queue = recipients.filter((r) => {
        const k = r.email.toLowerCase();
        if (seen.has(k)) return false;
        seen.add(k);
        return true;
      });
      let next = 0, attempted = 0, sent = 0, failed = 0;
      const worker = async () => {
        while (next < queue.length && !outOfTime()) {
          const r = queue[next++];
          attempted++;
          let ok = false;
          try {
            ok = await deps.send(r.email, template, { name: r.first_name ?? "there", exam });
          } catch {
            ok = false;
          }
          if (ok) sent++;
          else failed++;
          if (next < queue.length) await deps.sleep(PACE_MS);
        }
      };
      await Promise.all(Array.from({ length: Math.min(MAX_PARALLEL, queue.length) }, worker));
      return { total: queue.length, attempted, sent, failed, unsent: queue.length - attempted };
    }

    const logOutcome = (kind: string, o: Outcome) =>
      console.log(
        `[paper-release-notify] ${kind} attempted=${o.attempted} sent=${o.sent} failed=${o.failed} unsent=${o.unsent} retry=${o.retry}`,
      );

    const due = await svc.rpc("paper_release_due");
    if (due.error) {
      console.error(`[paper-release-notify] due lookup failed code=${due.error.code ?? "unknown"}`);
      failures++;
    }
    for (const e of (due.data ?? []) as { exam_id: string; title: string; paper: string | null }[]) {
      if (outOfTime()) break;
      const claimedAt = new Date(deps.now()).toISOString();
      const claim = await svc.from("exams").update({ release_notified_at: claimedAt })
        .eq("id", e.exam_id).is("release_notified_at", null).eq("release_held", false).select("id");
      if (claim.error || !claim.data?.length) {
        if (claim.error) failures++;
        continue;
      }
      const who = await svc.rpc("paper_release_recipients", { p_exam: e.exam_id });
      let r: Omit<Outcome, "exam_id" | "retry">;
      if (who.error) {
        console.error(`[paper-release-notify] recipients failed code=${who.error.code ?? "unknown"}`);
        failures++;
        r = { total: 1, attempted: 1, sent: 0, failed: 1, unsent: 0 }; // roll back and retry
      } else {
        r = await sendAll((who.data ?? []) as Recipient[], "paper_released", label(e.title, e.paper));
      }
      const retry = r.sent === 0 && r.total > 0;
      if (retry) {
        const back = await svc.from("exams").update({ release_notified_at: null }).eq("id", e.exam_id)
          .eq("release_notified_at", claimedAt);
        if (back.error) failures++;
      }
      const o = { exam_id: e.exam_id, ...r, retry };
      released.push(o);
      logOutcome("released", o);
    }

    const fixed = await svc.rpc("paper_corrected_due");
    if (fixed.error) {
      console.error(`[paper-release-notify] corrected lookup failed code=${fixed.error.code ?? "unknown"}`);
      failures++;
    }
    for (
      const e of (fixed.data ?? []) as { exam_id: string; title: string; paper: string | null; paper_ids: string[] }[]
    ) {
      if (outOfTime()) break;
      const claimedAt = new Date(deps.now()).toISOString();
      const claim = await svc.from("exam_papers").update({ corrected_notified_at: claimedAt })
        .in("id", e.paper_ids).is("corrected_notified_at", null).select("id");
      if (claim.error || !claim.data?.length) {
        if (claim.error) failures++;
        continue;
      }
      const ids = claim.data.map((p) => p.id as string);
      const who = await svc.rpc("paper_corrected_recipients", { p_paper_ids: ids });
      let r: Omit<Outcome, "exam_id" | "retry">;
      if (who.error) {
        console.error(`[paper-release-notify] recipients failed code=${who.error.code ?? "unknown"}`);
        failures++;
        r = { total: 1, attempted: 1, sent: 0, failed: 1, unsent: 0 };
      } else {
        r = await sendAll((who.data ?? []) as Recipient[], "paper_corrected", label(e.title, e.paper));
      }
      const retry = r.sent === 0 && r.total > 0;
      if (retry) {
        const back = await svc.from("exam_papers").update({ corrected_notified_at: null }).in("id", ids)
          .eq("corrected_notified_at", claimedAt);
        if (back.error) failures++;
      }
      const o = { exam_id: e.exam_id, ...r, retry };
      corrected.push(o);
      logOutcome("corrected", o);
    }

    console.log(
      `[paper-release-notify] released_exams=${released.length} corrected_exams=${corrected.length} failures=${failures}`,
    );
    return jsonResponse({ released, corrected });
  };
}
