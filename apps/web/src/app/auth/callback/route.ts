import { NextResponse, type NextRequest } from "next/server";
import type { EmailOtpType } from "@supabase/supabase-js";
import { homeFor } from "@stem/shared";
import { createClient } from "@/lib/supabase/server";

const OTP_TYPES = ["signup", "recovery", "invite", "email", "magiclink", "email_change"] as const;

/**
 * Email link landing: PKCE `?code=` (links sent by the app) or `?token_hash=&type=` (admin-generated
 * links and custom templates). Recovery and invite sessions go to "set your password"; everything else
 * goes to the home of the account.
 */
export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl;
  const supabase = await createClient();
  // Any failure ends with no session left behind.
  const fail = async () => {
    // Local scope only: a junk link must not be able to sign the user out of their other devices.
    await supabase.auth.signOut({ scope: "local" });
    return NextResponse.redirect(new URL("/login?error=link", request.url));
  };

  const code = searchParams.get("code");
  const tokenHash = searchParams.get("token_hash");
  const type = searchParams.get("type");
  let setPassword = false;

  // Decides from the verified session, never from the query type, whether the user must choose a password.
  // GoTrue accepts a recovery token under any email-style type and signs every OTP session "otp", so the
  // reliable signal is the account itself: a recovery email sent within the token lifetime (1 hour).
  // Unreadable claims or user fail closed (set a password).
  const needsPassword = async () => {
    const { data: claims } = await supabase.auth.getClaims();
    const amr = claims?.claims?.amr;
    if (!Array.isArray(amr)) return true;
    const methods = (amr as Array<string | { method?: string }>).map((m) => (typeof m === "string" ? m : (m.method ?? "")));
    if (methods.includes("recovery") || methods.includes("invite")) return true;
    const { data: auth } = await supabase.auth.getUser();
    if (!auth.user) return true;
    const sent = auth.user.recovery_sent_at ? Date.parse(auth.user.recovery_sent_at) : NaN;
    return Number.isFinite(sent) && Date.now() - sent < 60 * 60 * 1000;
  };

  if (tokenHash && type && (OTP_TYPES as readonly string[]).includes(type)) {
    const { error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type: type as EmailOtpType });
    if (error) return fail();
    // Trust the verified session, never the query type: a recovery link edited to another type must not skip this.
    setPassword = type === "recovery" || type === "invite" || (await needsPassword());
  } else if (code) {
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (error) return fail();
    setPassword = await needsPassword();
  } else {
    return fail();
  }

  if (setPassword) return NextResponse.redirect(new URL("/reset-password?mode=set", request.url));

  const { data: auth } = await supabase.auth.getUser();
  const { data: profile } = auth.user
    ? await supabase.from("profiles").select("role, status").eq("id", auth.user.id).maybeSingle()
    : { data: null };
  if (!profile) return fail();
  return NextResponse.redirect(new URL(homeFor(profile.role, profile.status, "web-staff"), request.url));
}
