// Creates the single owner account and emails a set-password link.
//
//   npm run setup:owner -- <email> <first name> <last name>
//
// Targets the LIVE project: it reads SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY from
// .env.prod.local (create that file for the live project first). The dev project never holds a
// real owner (the test suites need that slot), so the script refuses when the URL equals the
// one in .env.dev.local, unless --allow-dev is passed, which is only for testing the script with
// a throwaway owner that is deleted afterwards (it then reads .env.dev.local).
//
// Runs on Node >= 22.9 (native TypeScript type stripping, no build step). Refuses when an owner
// already exists, with one exception: if the only owner has this exact email and its invite
// email never went out, the email is re-sent. The invite link and token are never printed; the
// email goes out through the project's auth mailer.
import { existsSync, readFileSync } from "node:fs";
import { parseEnv } from "node:util";
import { createClient } from "@supabase/supabase-js";

function fail(message: string): never {
  console.error(message);
  process.exit(1);
}

function readEnvFile(path: string): Record<string, string | undefined> {
  return existsSync(path) ? parseEnv(readFileSync(path, "utf8")) : {};
}

const allowDev = process.argv.includes("--allow-dev");
const [rawEmail, firstName, lastName] = process.argv.slice(2).filter((a) => a !== "--allow-dev");
if (!rawEmail || !firstName || !lastName) {
  fail("Usage: npm run setup:owner -- <email> <first name> <last name> [--allow-dev]");
}
const email = rawEmail.trim().toLowerCase();
if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) fail("That does not look like an email address.");

const devEnv = readEnvFile(".env.dev.local");
let env: Record<string, string | undefined>;
if (allowDev) {
  env = devEnv;
} else {
  if (!existsSync(".env.prod.local")) fail("Create .env.prod.local for the live project first");
  env = readEnvFile(".env.prod.local");
}
const url = env.SUPABASE_URL;
const key = env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) fail("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in the env file.");
if (!allowDev && devEnv.SUPABASE_URL && url.replace(/\/+$/, "") === devEnv.SUPABASE_URL.replace(/\/+$/, "")) {
  fail("That is the dev project, which must never hold a real owner. Nothing was changed.");
}

const svc = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

async function sendRecovery(userId: string): Promise<never> {
  // Sends the standard recovery (set-password) email. The link itself never passes through here.
  const { error } = await svc.auth.resetPasswordForEmail(email);
  if (error) {
    fail(
      "The owner account exists, but the invite email could not be sent. " +
        "Run this command again with the same email to retry, or send a password recovery email " +
        "from the Supabase dashboard (Authentication > Users).",
    );
  }
  await svc.from("profiles").update({ invite_sent_at: new Date().toISOString() }).eq("id", userId);
  console.log(`Owner invite sent to ${email.split("@")[1]}`);
  process.exit(0);
}

const { data: owners, error: ownerErr } = await svc
  .from("profiles").select("id, email, invite_sent_at").eq("role", "owner");
if (ownerErr) fail(`Could not check for an existing owner (${ownerErr.code ?? "error"}).`);
if (owners.length > 0) {
  const o = owners[0];
  if (owners.length === 1 && String(o.email).toLowerCase() === email && o.invite_sent_at === null) {
    await sendRecovery(o.id);
  }
  fail("An owner already exists. Nothing was changed.");
}

const { count: taken, error: takenErr } = await svc
  .from("profiles").select("*", { count: "exact", head: true }).eq("email", email);
if (takenErr) fail(`Could not check the email (${takenErr.code ?? "error"}).`);

// Atomic reservation: insert … on conflict do nothing, then re-read.
const { error: invErr } = await svc
  .from("pending_invites")
  .upsert({ email, role: "owner" }, { onConflict: "email", ignoreDuplicates: true });
if (invErr) fail(`Could not create the invite (${invErr.code ?? "error"}).`);
const { data: invite, error: readErr } = await svc
  .from("pending_invites").select("token, role").eq("email", email).maybeSingle();
if (readErr || !invite) fail("Could not read the invite back. Nothing was changed; try again.");
if (invite.role !== "owner") fail("A different pending invite exists for this email. Nothing was changed.");
const token: string = invite.token;

if ((taken ?? 0) > 0) {
  // Only an interrupted run of this very command (a sign-up shell carrying this token) may continue.
  const { data: shell } = await svc.from("profiles").select("id, role").eq("email", email).maybeSingle();
  const { data: au } = shell ? await svc.auth.admin.getUserById(shell.id) : { data: null };
  if (!shell || shell.role !== "student" || au?.user?.app_metadata?.invite_token !== token) {
    fail("An account with this email already exists. Nothing was changed.");
  }
}

let userId: string;
const { data: created, error: createErr } = await svc.auth.admin.createUser({
  email,
  email_confirm: true,
  app_metadata: { invite_token: token },
  user_metadata: { first_name: firstName.trim(), last_name: lastName.trim() },
});
if (created?.user) {
  userId = created.user.id;
} else {
  // Resume an interrupted run: the existing shell must carry this exact invite token.
  const { data: shell } = await svc.from("profiles").select("id, role").eq("email", email).maybeSingle();
  const { data: au } = shell ? await svc.auth.admin.getUserById(shell.id) : { data: null };
  if (!shell || au?.user?.app_metadata?.invite_token !== token) {
    fail(`Could not create the user (${createErr?.code ?? createErr?.status ?? "error"}). Nothing was deleted.`);
  }
  userId = shell.id;
}

const { data: claim, error: claimErr } = await svc.rpc("claim_invite", {
  p_user: userId,
  p_token: token,
  p_email: email,
  p_role: "owner",
});
if (claimErr) {
  // Unknown state: never delete anything. If the profile is already an owner, carry on.
  const { data: now } = await svc.from("profiles").select("role").eq("id", userId).maybeSingle();
  if (now?.role !== "owner") {
    fail("Could not confirm the new owner account. Nothing was deleted; run this command again to continue.");
  }
} else if (claim !== "claimed" && claim !== "already") {
  // Definite refusal: remove only what this run created.
  await svc.auth.admin.deleteUser(userId);
  await svc.from("pending_invites").delete().eq("email", email);
  fail("Could not promote the new account to owner. Nothing was changed.");
}
await svc.auth.admin.updateUserById(userId, { app_metadata: { invite_token: null } });
await sendRecovery(userId);
