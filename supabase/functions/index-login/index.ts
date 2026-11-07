import { createClient } from "@supabase/supabase-js";
import { serviceClient } from "../_shared/auth.ts";
import { HttpError, handle, jsonResponse } from "../_shared/errors.ts";

const BAD_LOGIN = "Index number or password is incorrect.";

function normaliseIndex(raw: string): string {
  let s = raw.toUpperCase().replace(/\s+/g, "");
  const m = /^SE(\d{4})(\d{4,})$/.exec(s);
  if (m) s = `SE-${m[1]}-${m[2]}`;
  return s;
}

Deno.serve(handle(async (req) => {
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

  // Rate limit first, before any lookup or password verification.
  const { data: allowed, error: checkErr } = await svc.rpc("login_attempt_check", { p_ip_key: ipKey, p_idx_key: idxKey });
  if (checkErr) {
    console.error("login_attempt_check failed:", checkErr.code ?? "unknown");
    throw new HttpError("internal", 500, "Something went wrong. Please try again.");
  }
  if (allowed !== true) throw new HttpError("rate_limited", 429, "Too many attempts. Try again later.");

  const fail = async (): Promise<never> => {
    const { error } = await svc.rpc("login_attempt_fail", { p_ip_key: ipKey, p_idx_key: idxKey });
    if (error) console.error("login_attempt_fail failed:", error.code ?? "unknown");
    throw new HttpError("invalid_credentials", 401, BAD_LOGIN);
  };

  // Look up the account email (never returned to the caller).
  let email: string | null = null;
  if (/^SE-\d{4}-\d{4,}$/.test(index)) {
    const { data: det, error: dErr } = await svc.from("student_details").select("profile_id")
      .eq("index_number", index).maybeSingle();
    if (dErr) {
      console.error("index lookup failed:", dErr.code ?? "unknown");
      throw new HttpError("internal", 500, "Something went wrong. Please try again.");
    }
    if (det) {
      const { data: prof, error: pErr } = await svc.from("profiles").select("email, role")
        .eq("id", det.profile_id).maybeSingle();
      if (pErr) {
        console.error("profile lookup failed:", pErr.code ?? "unknown");
        throw new HttpError("internal", 500, "Something went wrong. Please try again.");
      }
      if (prof && prof.role === "student" && typeof prof.email === "string") email = prof.email;
    }
  }

  const anon = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // Unknown index: still perform a sign-in attempt so response timing is comparable.
  const { data, error } = await anon.auth.signInWithPassword({
    email: email ?? "no-such-account@invalid.example",
    password,
  });
  if (!email || error || !data.session) return await fail();

  const { error: clearErr } = await svc.rpc("login_attempt_clear", { p_idx_key: idxKey });
  if (clearErr) console.error("login_attempt_clear failed:", clearErr.code ?? "unknown");

  return jsonResponse({
    access_token: data.session.access_token,
    refresh_token: data.session.refresh_token,
    expires_in: data.session.expires_in,
  });
}));
