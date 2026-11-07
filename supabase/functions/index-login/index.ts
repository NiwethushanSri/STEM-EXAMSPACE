import { createClient } from "@supabase/supabase-js";
import { serviceClient } from "../_shared/auth.ts";
import { HttpError, handle, jsonResponse } from "../_shared/errors.ts";

const MIN_MS = 600;
const BAD_LOGIN = "Index number or password is incorrect.";

function normaliseIndex(raw: string): string {
  let s = raw.toUpperCase().replace(/\s+/g, "");
  const m = /^SE(\d{4})(\d{4,})$/.exec(s);
  if (m) s = `SE-${m[1]}-${m[2]}`;
  return s;
}

Deno.serve(handle(async (req) => {
  const started = Date.now();
  if (req.method !== "POST") throw new HttpError("invalid_input", 405, "Use POST.");

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    throw new HttpError("invalid_input", 400, "Invalid request body.");
  }
  const { indexNumber, password } = (body ?? {}) as { indexNumber?: unknown; password?: unknown };
  if (
    typeof indexNumber !== "string" || indexNumber.length === 0 || indexNumber.length > 40 ||
    typeof password !== "string" || password.length === 0 || password.length > 200
  ) {
    throw new HttpError("invalid_input", 400, "Enter your index number and password.");
  }

  const index = normaliseIndex(indexNumber);
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  const ipKey = `ip:${ip}`;
  const idxKey = `idx:${index}`;
  const svc = serviceClient();

  // Every non-200 response after the begin step takes at least MIN_MS, so timing does not reveal
  // whether an index exists.
  const pad = async () => {
    const left = MIN_MS - (Date.now() - started);
    if (left > 0) await new Promise((r) => setTimeout(r, left));
  };
  const reject = async (status: 401 | 500): Promise<never> => {
    await pad();
    if (status === 401) throw new HttpError("invalid_credentials", 401, BAD_LOGIN);
    throw new HttpError("internal", 500, "Something went wrong. Please try again.");
  };
  const refund = async () => {
    const { error } = await svc.rpc("login_attempt_refund", { p_ip_key: ipKey, p_idx_key: idxKey });
    if (error) console.error("login_attempt_refund failed:", error.code ?? "unknown");
  };

  // Atomic limit check + attempt record, before any lookup or password verification.
  const { data: allowed, error: beginErr } = await svc.rpc("login_attempt_begin", { p_ip_key: ipKey, p_idx_key: idxKey });
  if (beginErr) {
    console.error("login_attempt_begin failed:", beginErr.code ?? "unknown");
    return await reject(500);
  }
  if (allowed !== true) throw new HttpError("rate_limited", 429, "Too many attempts. Try again later.");

  // Look up the account email (never returned to the caller).
  let email: string | null = null;
  if (/^SE-\d{4}-\d{4,}$/.test(index)) {
    const { data: det, error: dErr } = await svc.from("student_details").select("profile_id")
      .eq("index_number", index).maybeSingle();
    if (dErr) {
      console.error("index lookup failed:", dErr.code ?? "unknown");
      await refund();
      return await reject(500);
    }
    if (det) {
      const { data: prof, error: pErr } = await svc.from("profiles").select("email, role")
        .eq("id", det.profile_id).maybeSingle();
      if (pErr) {
        console.error("profile lookup failed:", pErr.code ?? "unknown");
        await refund();
        return await reject(500);
      }
      if (prof && prof.role === "student" && typeof prof.email === "string") email = prof.email;
    }
  }
  // Unknown index: the attempt row stays (counts toward the limit); no sign-in is made.
  if (!email) return await reject(401);

  const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await anon.auth.signInWithPassword({ email, password });
  if (error || !data.session) {
    // Only an invalid-credentials answer is a failed login; anything else is an infrastructure error.
    const bad = error && (error.code === "invalid_credentials" || error.status === 400);
    if (bad) return await reject(401);
    console.error("sign in failed:", error?.code ?? String(error?.status ?? "unknown"));
    await refund();
    return await reject(500);
  }

  const { error: okErr } = await svc.rpc("login_attempt_succeed", { p_ip_key: ipKey, p_idx_key: idxKey });
  if (okErr) console.error("login_attempt_succeed failed:", okErr.code ?? "unknown");

  return jsonResponse({
    access_token: data.session.access_token,
    refresh_token: data.session.refresh_token,
    expires_in: data.session.expires_in,
  });
}));
