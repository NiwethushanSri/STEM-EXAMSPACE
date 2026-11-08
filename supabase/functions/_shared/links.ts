/**
 * Link emailed to a user for setting a password or confirming an address. It points at the web app's
 * /auth/callback with the hashed token (verified server side with verifyOtp), because GoTrue's own
 * action_link puts the tokens in the URL fragment, which a server route never receives.
 * Keep the format in sync with apps/web/e2e/admin.ts (authLinkPath).
 */
export function buildAuthLink(hashedToken: string, type: "recovery" | "signup" | "invite"): string {
  const site = Deno.env.get("SITE_URL");
  if (!site) throw new Error("SITE_URL is not configured for this project");
  return `${site.replace(/\/+$/, "")}/auth/callback?token_hash=${encodeURIComponent(hashedToken)}&type=${type}`;
}
