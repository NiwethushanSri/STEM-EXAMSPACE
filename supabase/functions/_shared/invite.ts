import type { SupabaseClient } from "@supabase/supabase-js";
import { sendEmail } from "./email.ts";
import type { AppRole } from "./auth.ts";

export type ClaimResult = "claimed" | "already" | "refused" | "error";

export interface ProvisionInput {
  email: string; // already lowercased/trimmed
  token: string; // pending_invites.token for this email
  role: AppRole; // the role the invite carries
  firstName: string;
  lastName: string;
}

export interface ProvisionResult {
  /** The invited account (claimed by this or a concurrent request); null when nothing usable exists. */
  userId: string | null;
  /** True only when THIS request's claim changed the role (so this request owes the invite email). */
  invited: boolean;
  warning?: "email_in_use";
}

const wait = (ms: number) => new Promise((res) => setTimeout(res, ms));

async function dropInvite(svc: SupabaseClient, email: string) {
  const { error } = await svc.from("pending_invites").delete().eq("email", email);
  if (error) console.error("invite cleanup failed:", error.code ?? "unknown");
}

async function dropUser(svc: SupabaseClient, id: string) {
  const { error } = await svc.auth.admin.deleteUser(id);
  if (error) console.error("orphan user cleanup failed for", id, error.status ?? "unknown");
}

/**
 * Claims the sign-up shell GoTrue created for an invite. 'already' is only trusted
 * when the profile really has the invited role.
 */
export async function claimInvite(
  svc: SupabaseClient,
  userId: string,
  token: string,
  email: string,
  role: AppRole,
): Promise<ClaimResult> {
  const { data, error } = await svc.rpc("claim_invite", { p_user: userId, p_token: token, p_email: email });
  if (error) {
    console.error("claim rpc failed:", error.code ?? "unknown");
    return "error";
  }
  if (data === "claimed") return "claimed";
  if (data === "already") {
    const { data: p } = await svc.from("profiles").select("role").eq("id", userId).maybeSingle();
    return p?.role === role ? "already" : "refused";
  }
  return "refused";
}

/**
 * createUser + claim for a pending invite, including the heal paths for crashed or concurrent
 * attempts. Never compensates (deletes anything) when the account state is unknown.
 */
export async function provisionInvitedUser(svc: SupabaseClient, input: ProvisionInput): Promise<ProvisionResult> {
  const { email, token, role } = input;
  const claim = (id: string) => claimInvite(svc, id, token, email, role);

  const { data: created, error: cErr } = await svc.auth.admin.createUser({
    email,
    email_confirm: true,
    app_metadata: { invite_token: token },
    user_metadata: { first_name: input.firstName, last_name: input.lastName },
  });

  if (!cErr && created.user) {
    // GoTrue writes app_metadata after the insert, so the sign-up trigger cannot apply the invite.
    const uid = created.user.id;
    let r = await claim(uid);
    let unknown = false;
    if (r === "error") {
      // Transport failure: find out what state the account is in before touching anything.
      const { data: now, error: rErr } = await svc.from("profiles").select("role").eq("id", uid).maybeSingle();
      if (rErr || !now) {
        unknown = true;
        console.error("claim state unknown for", uid, rErr?.code ?? "no row");
      } else if (now.role === role) {
        r = "claimed";
      }
    }
    if (r === "claimed" || r === "already") return { userId: uid, invited: r === "claimed" };
    // Leave the shell and invite for a retry to heal when the state is unknown.
    if (unknown) return { userId: null, invited: false };
    console.error("invite claim failed");
    await dropUser(svc, uid);
    await dropInvite(svc, email);
    return { userId: null, invited: false };
  }

  if (!cErr) return { userId: null, invited: false };
  console.error("createUser failed:", cErr.status ?? "unknown", cErr.code ?? "unknown");

  // Another request (or a crashed earlier one) may own this account: heal it if it carries this invite.
  const { data: existing } = await svc.from("profiles").select("id, role").eq("email", email).maybeSingle();
  let mine = existing?.role === role;
  if (existing && !mine) {
    const { data: au } = await svc.auth.admin.getUserById(existing.id);
    const tok = au?.user?.app_metadata?.invite_token;
    const age = au?.user ? Date.now() - new Date(au.user.created_at).getTime() : Infinity;
    // GoTrue writes app_metadata after the insert: a very fresh shell without a token yet is the
    // concurrent request mid-creation. The claim (retried below) is the real gate.
    mine = tok === token || (tok === undefined && age < 60_000 && existing.role === "student");
  }
  if (existing && mine) {
    let r: ClaimResult = "refused";
    for (let i = 0; i < 5; i++) {
      r = await claim(existing.id);
      if (r === "claimed" || r === "already") break;
      await wait(200);
    }
    if (r === "claimed" || r === "already") return { userId: existing.id, invited: r === "claimed" };
    console.error("could not claim existing account");
    return { userId: null, invited: false }; // the invite is never deleted in this branch
  }
  await dropInvite(svc, email);
  return {
    userId: null,
    invited: false,
    warning: /already|registered|exists/i.test(cErr.message) ? "email_in_use" : undefined,
  };
}

/** Removes the one-time token from the auth user's app_metadata. Failure is logged only. */
export async function clearInviteToken(svc: SupabaseClient, userId: string): Promise<void> {
  const { error } = await svc.auth.admin.updateUserById(userId, { app_metadata: { invite_token: null } });
  if (error) console.error("invite token clear failed:", error.status ?? "unknown");
}

/**
 * Generates a recovery link, emails it and, if sent, stamps profiles.invite_sent_at.
 * The link is never returned or logged.
 */
export async function sendInviteEmail(svc: SupabaseClient, userId: string, email: string): Promise<boolean> {
  const { data: link } = await svc.auth.admin.generateLink({ type: "recovery", email });
  const actionLink = link?.properties?.action_link;
  if (!actionLink) return false;
  const sent = await sendEmail(email, "invite", { link: actionLink });
  if (sent) {
    const { error } = await svc.from("profiles")
      .update({ invite_sent_at: new Date().toISOString() }).eq("id", userId);
    if (error) console.error("invite_sent_at update failed:", error.code ?? "unknown");
  }
  return sent;
}

/** Links a parent to a student, then to every other approved, unlinked student sharing the parent email. */
export async function linkParent(svc: SupabaseClient, parentId: string, studentId: string): Promise<boolean> {
  const { error } = await svc.from("parent_children")
    .upsert({ parent_id: parentId, student_id: studentId }, { onConflict: "parent_id,student_id", ignoreDuplicates: true });
  if (error) {
    console.error("parent link failed:", error.code ?? "unknown");
    return false;
  }
  await reconcileParent(svc, parentId);
  return true;
}

export async function reconcileParent(svc: SupabaseClient, parentId: string): Promise<void> {
  const { error } = await svc.rpc("link_children_to_parent", { p_parent: parentId });
  if (error) console.error("sibling link failed:", error.code ?? "unknown");
}
