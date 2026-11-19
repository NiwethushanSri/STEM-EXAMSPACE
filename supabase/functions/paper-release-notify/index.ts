// Called every minute by pg_cron (through pg_net, with the x-cron-secret header). Emails the families of home
// bookings when their exam's paper is released, and once when a paper they downloaded is replaced.
// The database chooses what is due and who gets it (paper_release_due and friends, all bounded by a 6-hour window).
// Without EMAIL_PROVIDER nothing is sent and nothing is marked, so turning email on later cannot announce old
// releases. With one, an exam or paper is claimed (marked) before sending so overlapping runs cannot send twice.
// Logs hold counts and error codes only, never an address or a name.
import { serviceClient } from "../_shared/auth.ts";
import { sendEmail } from "../_shared/email.ts";
import { errorResponse, handle, jsonResponse } from "../_shared/errors.ts";

interface Recipient {
  email: string;
  first_name: string | null;
}
interface Outcome {
  exam_id: string;
  sent: number;
}

/** Compares without leaking where the first difference is. */
function sameSecret(given: string | null, expected: string): boolean {
  const enc = new TextEncoder();
  const a = enc.encode(given ?? "");
  const b = enc.encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) diff |= (a[i] ?? 0) ^ b[i];
  return diff === 0;
}

/** "GCSE Maths Paper 1": the exam title and its paper, without repeating the paper if the title has it. */
function label(title: string, paper: string | null): string {
  const p = (paper ?? "").trim();
  return p && !title.toLowerCase().includes(p.toLowerCase()) ? `${title} ${p}` : title;
}

async function sendAll(
  recipients: Recipient[],
  template: "paper_released" | "paper_corrected",
  exam: string,
): Promise<number> {
  let sent = 0;
  const seen = new Set<string>();
  for (const r of recipients) {
    const key = r.email.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    if (await sendEmail(r.email, template, { name: r.first_name ?? "there", exam })) sent++;
  }
  return sent;
}

Deno.serve(handle(async (req) => {
  if (req.method !== "POST") return errorResponse("invalid_input", "Use POST.", 405);
  const expected = Deno.env.get("CRON_SECRET") ?? "";
  if (!expected || !sameSecret(req.headers.get("x-cron-secret"), expected)) {
    return errorResponse("unauthenticated", "Not allowed.", 401);
  }
  await req.body?.cancel();

  const released: Outcome[] = [];
  const corrected: Outcome[] = [];
  if (!Deno.env.get("EMAIL_PROVIDER")) {
    console.error("[paper-release-notify] email is off: nothing sent, nothing marked");
    return jsonResponse({ skipped: true, released, corrected });
  }

  const svc = serviceClient();
  let failures = 0;

  const due = await svc.rpc("paper_release_due");
  if (due.error) {
    console.error(`[paper-release-notify] due lookup failed code=${due.error.code ?? "unknown"}`);
    failures++;
  }
  for (const e of (due.data ?? []) as { exam_id: string; title: string; paper: string | null }[]) {
    const claim = await svc.from("exams").update({ release_notified_at: new Date().toISOString() })
      .eq("id", e.exam_id).is("release_notified_at", null).eq("release_held", false).select("id");
    if (claim.error || !claim.data?.length) {
      if (claim.error) failures++;
      continue;
    }
    const who = await svc.rpc("paper_release_recipients", { p_exam: e.exam_id });
    if (who.error) {
      console.error(`[paper-release-notify] recipients failed code=${who.error.code ?? "unknown"}`);
      failures++;
      continue;
    }
    released.push({ exam_id: e.exam_id, sent: await sendAll((who.data ?? []) as Recipient[], "paper_released", label(e.title, e.paper)) });
  }

  const fixed = await svc.rpc("paper_corrected_due");
  if (fixed.error) {
    console.error(`[paper-release-notify] corrected lookup failed code=${fixed.error.code ?? "unknown"}`);
    failures++;
  }
  for (
    const e of (fixed.data ?? []) as { exam_id: string; title: string; paper: string | null; paper_ids: string[] }[]
  ) {
    const claim = await svc.from("exam_papers").update({ corrected_notified_at: new Date().toISOString() })
      .in("id", e.paper_ids).is("corrected_notified_at", null).select("id");
    if (claim.error || !claim.data?.length) {
      if (claim.error) failures++;
      continue;
    }
    const who = await svc.rpc("paper_corrected_recipients", { p_paper_ids: claim.data.map((p) => p.id as string) });
    if (who.error) {
      console.error(`[paper-release-notify] recipients failed code=${who.error.code ?? "unknown"}`);
      failures++;
      continue;
    }
    corrected.push({ exam_id: e.exam_id, sent: await sendAll((who.data ?? []) as Recipient[], "paper_corrected", label(e.title, e.paper)) });
  }

  console.log(
    `[paper-release-notify] released_exams=${released.length} emails=${
      released.reduce((n, r) => n + r.sent, 0)
    } corrected_exams=${corrected.length} emails=${corrected.reduce((n, r) => n + r.sent, 0)} failures=${failures}`,
  );
  return jsonResponse({ released, corrected });
}));
