// Emails the notices about scripts that the database queued (migration 055): a receipt when a home submission is
// received, a note when pages need attention or the submission is rejected (to the student and linked parents),
// and an alert to staff when a script exception needs them. The database decides what is due and who each notice
// is for (script_notice_next claims notices before they are sent, so two runs never send the same one); this
// function only sends. The database hands out the families' notices before staff alerts, and one staff alert per
// kind of problem and file, with how many problems it is about (migration 076). A marking alert (migration 008: a
// picture changed or went while a script was being marked, a marker reported a visible name, pages were set aside or
// changed) goes to the subject's lead marker and the owner and admin accounts, handed out as a staff alert is; one
// email per exam and kind while it waits, with how many scripts it is about.
//
// Rules:
// - Without EMAIL_PROVIDER nothing is sent and nothing is claimed or marked, so turning email on later cannot
//   announce old events.
// - Each recipient is recorded (script_notice_record) just before their email and forgotten again only if that send
//   fails, so nobody gets the same notice twice, whatever fails, times out or overlaps. A notice is marked sent when
//   every email went out; otherwise the database hands it out again after a wait (at most 3 tries), with only the
//   people not yet recorded.
// - No new send starts after BUDGET_MS. Notices claimed but not sent in time are retried by the database after 5 minutes.
// Logs hold counts, kinds and error codes only, never an address or a name.
import type { SupabaseClient } from "@supabase/supabase-js";
import { errorResponse, jsonResponse } from "../_shared/errors.ts";

/** Wait after each email: about 2 requests a second. */
export const PACE_MS = 500;
/** Stop starting sends after this long (the Edge Function wall-clock limit is higher). */
export const BUDGET_MS = 100_000;

export type ScriptTemplate = "script_receipt" | "script_attention" | "script_rejected" | "script_staff_alert" | "script_marking_alert";

export interface Deps {
  env: (name: string) => string | undefined;
  svc: () => SupabaseClient;
  send: (to: string, template: ScriptTemplate, data: Record<string, string>) => Promise<boolean>;
  now: () => number;
  sleep: (ms: number) => Promise<void>;
}

export interface Notice {
  id: number;
  kind: "receipt" | "needs_attention" | "rejected" | "staff_alert" | "marking_alert";
  recipients: { profile_id: string; email: string; first_name: string | null }[];
  exam: string | null;
  script_number: string | null;
  submission_seq: number | null;
  at: string | null;
  page_count: number | null;
  pages: number[] | null;
  exception_kind: string | null;
  /** How many problems a staff alert is about (pages of one file, or scripts of one exam), or how many marking alerts of
   * one exam and kind a marking alert is about. */
  count?: number | null;
  /** A marking alert's kind: picture_changed, picture_missing, name_visible, pages_set_aside or pages_changed. */
  alert_kind?: string | null;
}

const TEMPLATES: Record<Notice["kind"], ScriptTemplate> = {
  receipt: "script_receipt",
  needs_attention: "script_attention",
  rejected: "script_rejected",
  staff_alert: "script_staff_alert",
  marking_alert: "script_marking_alert",
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
  if (n.kind === "staff_alert") return { ...d, kind: n.exception_kind ?? "", count: String(n.count && n.count > 0 ? n.count : 1) };
  if (n.kind === "marking_alert") return { ...d, kind: n.alert_kind ?? "", count: String(n.count && n.count > 0 ? n.count : 1) };
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

    // One notice at a time, and the time is checked before each is claimed, so no attempt is used up without trying.
    while (!outOfTime()) {
      const next = await svc.rpc("script_notice_next", { p_limit: 1 });
      if (next.error) {
        console.error(`[script-notify] next failed code=${next.error.code ?? "unknown"}`);
        errors++;
        break;
      }
      const n = ((next.data ?? []) as Notice[])[0];
      if (!n) break;
      notices++;
      const template = TEMPLATES[n.kind];
      let ok = template !== undefined;
      for (const r of n.recipients ?? []) {
        if (outOfTime()) {
          ok = false; // the rest is left for the next run
          break;
        }
        // Recorded before the email goes out, and forgotten only if it fails: nobody is emailed twice.
        const rec = await svc.rpc("script_notice_record", { p_id: n.id, p_profile: r.profile_id });
        if (rec.error) {
          console.error(`[script-notify] record failed code=${rec.error.code ?? "unknown"}`);
          errors++;
          ok = false; // never send without a record
          continue;
        }
        if (rec.data === "stopped") break;
        if (rec.data !== "ok") continue; // someone else has sent it
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
          const un = await svc.rpc("script_notice_unmark", { p_id: n.id, p_profile: r.profile_id });
          if (un.error) errors++;
        }
        await deps.sleep(PACE_MS);
      }
      const m = await svc.rpc("script_notice_mark", { p_id: n.id, p_ok: ok });
      if (m.error) {
        console.error(`[script-notify] mark failed code=${m.error.code ?? "unknown"}`);
        errors++;
      }
    }

    const gave = await svc.rpc("script_notice_given_up");
    const givenUp = gave.error ? 0 : Number(gave.data ?? 0);
    if (givenUp > 0) console.error(`[script-notify] notices given up after 3 attempts: ${givenUp}`);

    console.log(`[script-notify] notices=${notices} sent=${sent} failed=${failed} errors=${errors} given_up=${givenUp}`);
    return jsonResponse({ notices, sent, failed, given_up: givenUp });
  };
}
