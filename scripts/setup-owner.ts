// Creates the first owner account and emails a set-password link.
//
//   npm run setup:owner -- <email> <first name> <last name>
//
// Runs on Node >= 22.9 (native TypeScript type stripping, so no build step) and reads
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY from the environment or from .env.dev.local
// (loaded by the npm script). Refuses when any owner already exists. The invite link and
// token are never printed; the email goes out through the project's own auth mailer.
import { createClient } from "@supabase/supabase-js";

function fail(message: string): never {
  console.error(message);
  process.exit(1);
}

const [rawEmail, firstName, lastName] = process.argv.slice(2);
if (!rawEmail || !firstName || !lastName) {
  fail('Usage: npm run setup:owner -- <email> <first name> <last name>');
}
const email = rawEmail.trim().toLowerCase();
if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) fail("That does not look like an email address.");

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) fail("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY (for example in .env.dev.local).");

const svc = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

const { count: owners, error: ownerErr } = await svc
  .from("profiles").select("*", { count: "exact", head: true }).eq("role", "owner");
if (ownerErr) fail(`Could not check for an existing owner (${ownerErr.code ?? "error"}).`);
if ((owners ?? 0) > 0) fail("An owner already exists. Nothing was changed.");

const { count: taken, error: takenErr } = await svc
  .from("profiles").select("*", { count: "exact", head: true }).eq("email", email);
if (takenErr) fail(`Could not check the email (${takenErr.code ?? "error"}).`);
if ((taken ?? 0) > 0) fail("An account with this email already exists. Nothing was changed.");

const token = crypto.randomUUID();
const { error: invErr } = await svc
  .from("pending_invites")
  .upsert({ email, role: "owner", token }, { onConflict: "email" });
if (invErr) fail(`Could not create the invite (${invErr.code ?? "error"}).`);

async function rollback(userId?: string) {
  if (userId) await svc.auth.admin.deleteUser(userId);
  await svc.from("pending_invites").delete().eq("email", email);
}

// GoTrue writes app_metadata after inserting the user, so the sign-up trigger yields a student
// shell; claim_invite promotes it using the token.
const { data: created, error: createErr } = await svc.auth.admin.createUser({
  email,
  email_confirm: true,
  app_metadata: { invite_token: token },
  user_metadata: { first_name: firstName.trim(), last_name: lastName.trim() },
});
if (createErr || !created.user) {
  await rollback();
  fail(`Could not create the user (${createErr?.code ?? createErr?.status ?? "error"}).`);
}
const userId = created.user.id;

const { data: claim, error: claimErr } = await svc.rpc("claim_invite", { p_user: userId, p_token: token, p_email: email });
if (claimErr || claim !== "claimed") {
  await rollback(userId);
  fail("Could not promote the new account to owner. Nothing was changed.");
}
await svc.auth.admin.updateUserById(userId, { app_metadata: { invite_token: null } });

// Sends the standard recovery (set-password) email. The link itself never passes through here.
const { error: mailErr } = await svc.auth.resetPasswordForEmail(email);
if (mailErr) {
  console.error(
    "The owner account was created, but the invite email could not be sent. " +
      "Send a password recovery email for it from the Supabase dashboard (Authentication > Users).",
  );
  process.exit(1);
}
await svc.from("profiles").update({ invite_sent_at: new Date().toISOString() }).eq("id", userId);
console.log(`Owner invite sent to ${email.split("@")[1]}`);
