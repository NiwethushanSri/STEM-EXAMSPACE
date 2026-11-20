// Emails the notices about scripts that the database queued (migration 055): a receipt when a home submission is
// received, a note when pages need attention or the submission is rejected (to the student and linked parents),
// and an alert to staff when a script exception needs them. The database decides what is due and who each notice
// is for (script_notice_next claims notices before they are sent, so two runs never send the same one); this
// function only sends.
//
// Rules:
// - Without EMAIL_PROVIDER nothing is sent and nothing is claimed or marked, so turning email on later cannot
//   announce old events.
// - A notice is marked sent only when every email of it went out. If one failed it is marked failed and the
//   database hands it out again after a wait (at most 3 tries), so a recipient who already got it may get it twice.
// - No new send starts after BUDGET_MS. Notices claimed but not sent in time are retried by the database after 5 minutes.
// Logs hold counts, kinds and error codes only, never an address or a name.
import type { SupabaseClient } from "@supabase/supabase-js";
import { errorResponse, jsonResponse } from "../_shared/errors.ts";

/** Notices claimed per database call. */
export const BATCH = 10;
/** Wait after each email: about 2 requests a second. */
export const PACE_MS = 500;
/** Stop starting sends after this long (the Edge Function wall-clock limit is higher). */
export const BUDGET_MS = 100_000;

export type ScriptTemplate = "script_receipt" | "script_attention" | "script_rejected" | "script_staff_alert";

export interface Deps {
  env: (name: string) => string | undefined;
  svc: () => SupabaseClient;
  send: (to: string, template: ScriptTemplate, data: Record<string, string>) => Promise<boolean>;
  now: () => number;
  sleep: (ms: number) => Promise<void>;
}

export interface Notice {
  id: number;
  kind: "receipt" | "needs_attention" | "rejected" | "staff_alert";
  recipients: { email: string; first_name: string | null }[];
  exam: string | null;
  script_number: string | null;
  submission_seq: number | null;
  at: string | null;
  page_count: number | null;
  pages: number[] | null;
  exception_kind: string | null;
}

const TEMPLATES: Record<Notice["kind"], ScriptTemplate> = {
  receipt: "script_receipt",
  needs_attention: "script_attention",
  rejected: "script_rejected",
  staff_alert: "script_staff_alert",
};

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

/** "7 June 2031 at 10:30", London time. */
export function londonTime(iso: string | null): string {
  const d = iso ? new Date(iso) : null;
  if (!d || Number.isNaN(d.getTime())) return "";
  const f = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/London", dateStyle: "long", timeStyle: "short" });
  return f.format(d).replace(",", " at");
}

/** The email data of a notice (strings only). Staff data never includes a name. */
export function dataFor(n: Notice, firstName: string | null): Record<string, string> {
  const d: Record<string, string> = { exam: n.exam ?? "", script_number: n.script_number ?? "" };
  if (n.kind === "staff_alert") return { ...d, kind: n.exception_kind ?? "" };
  d.name = firstName?.trim() || "there";
  if (n.kind === "receipt") {
    d.seq = n.submission_seq == null ? "" : String(n.submission_seq);
    d.time = londonTime(n.at);
    d.page_count = n.page_count == null ? "" : String(n.page_count);
    d.pages = (n.pages ?? []).join(", ");
  }
  return d;
}

export function makeHandler(deps: Deps): (req: Request) => Promise<Response> {
  return async (req) => {
    if (req.method !== "POST") return errorResponse("invalid_input", "Use POST.", 405);
    if (!sameSecret(req.headers.get("x-cron-secret"), deps.env("CRON_SECRET") ?? "")) {
      return errorResponse("unauthenticated", "Not allowed.", 401);
    }
    await req.body?.cancel();

    if (!deps.env("EMAIL_PROVIDER")) {
      console.error("[script-notify] email is off: nothing sent, nothing marked");
      return jsonResponse({ skipped: true, notices: 0, sent: 0, failed: 0 });
    }

    const started = deps.now();
    const outOfTime = () => deps.now() - started >= BUDGET_MS;
    const svc = deps.svc();
    let notices = 0, sent = 0, failed = 0, errors = 0;

    while (!outOfTime()) {
      const next = await svc.rpc("script_notice_next", { p_limit: BATCH });
      if (next.error) {
        console.error(`[script-notify] next failed code=${next.error.code ?? "unknown"}`);
        errors++;
        break;
      }
      const batch = (next.data ?? []) as Notice[];
      if (batch.length === 0) break;

      for (const n of batch) {
        notices++;
        const template = TEMPLATES[n.kind];
        let ok = template !== undefined;
        for (const r of n.recipients ?? []) {
          if (outOfTime()) {
            ok = false; // not tried: the database hands the notice out again
            break;
          }
          let sentOne = false;
          try {
            sentOne = await deps.send(r.email, template, dataFor(n, r.first_name));
          } catch {
            sentOne = false;
          }
          if (sentOne) sent++;
          else {
            failed++;
            ok = false;
          }
          await deps.sleep(PACE_MS);
        }
        const m = await svc.rpc("script_notice_mark", { p_id: n.id, p_ok: ok });
        if (m.error) {
          console.error(`[script-notify] mark failed code=${m.error.code ?? "unknown"}`);
          errors++;
        }
      }
      if (batch.length < BATCH) break;
    }

    console.log(`[script-notify] notices=${notices} sent=${sent} failed=${failed} errors=${errors}`);
    return jsonResponse({ notices, sent, failed });
  };
}
