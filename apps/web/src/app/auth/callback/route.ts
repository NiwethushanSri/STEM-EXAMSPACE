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
  const fail = () => NextResponse.redirect(new URL("/login?error=link", request.url));
  const supabase = await createClient();

  const code = searchParams.get("code");
  const tokenHash = searchParams.get("token_hash");
  const type = searchParams.get("type");
  let setPassword = type === "recovery" || type === "invite";

  if (tokenHash && type && (OTP_TYPES as readonly string[]).includes(type)) {
    const { error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type: type as EmailOtpType });
    if (error) return fail();
  } else if (code) {
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (error) return fail();
    // A PKCE link carries no type; the sign-in method of the session tells recovery and invite apart.
    const { data: claims } = await supabase.auth.getClaims();
    const methods = ((claims?.claims?.amr ?? []) as Array<string | { method?: string }>).map((m) =>
      typeof m === "string" ? m : (m.method ?? ""),
    );
    if (methods.includes("recovery") || methods.includes("invite")) setPassword = true;
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
