import { requireCaller, serviceClient } from "../_shared/auth.ts";
import { HttpError, handle, jsonResponse } from "../_shared/errors.ts";
import { sendEmail } from "../_shared/email.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface TxRow {
  index_number: string;
  parent_id: string | null;
  parent_email: string;
  invite_token: string | null;
}

function mapTxError(message: string, detail?: string | null): HttpError {
  switch (message) {
    case "conflict":
      return new HttpError("conflict", 409, "This registration was already handled.");
    case "parent_email_is_staff":
      return new HttpError(
        "parent_email_is_staff",
        409,
        detail === "student"
          ? "The parent email belongs to a student account. Edit the parent email first."
          : "The parent email belongs to a staff account. Edit the parent email first.",
      );
    case "invalid_input":
      return new HttpError("invalid_input", 400, "The student has no valid parent email.");
    default:
      return new HttpError("internal", 500, "Something went wrong. Please try again.");
  }
}

Deno.serve(handle(async (req) => {
  if (req.method !== "POST") throw new HttpError("invalid_input", 405, "Use POST.");
  const caller = await requireCaller(req, ["owner", "admin"]);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    throw new HttpError("invalid_input", 400, "Invalid request body.");
  }
  const studentId = (body as { studentId?: unknown } | null)?.studentId;
  if (typeof studentId !== "string" || !UUID.test(studentId)) {
    throw new HttpError("invalid_input", 400, "studentId must be a valid id.");
  }

  const svc = serviceClient();
  const { data, error } = await svc.rpc("approve_student_tx", {
    p_student: studentId,
    p_actor: caller.id,
  });
  if (error) {
    // SQL raises P0001 with a stable message; anything else is internal and not leaked.
    if (error.code === "P0001") throw mapTxError(error.message, error.details);
    console.error("approve_student_tx failed:", error.code ?? "unknown");
    throw new HttpError("internal", 500, "Something went wrong. Please try again.");
  }
  const row = (Array.isArray(data) ? data[0] : data) as TxRow | undefined;
  if (!row) throw new HttpError("internal", 500, "Something went wrong. Please try again.");

  // The approval is committed. Everything below is best effort and never fails the request.
  const parentEmail = row.parent_email;
  let parentInvited = false;
  let parentId = row.parent_id;
  let linked = row.parent_id !== null; // existing parent was linked inside the transaction
  let warning: string | undefined;

  const dropInvite = async () => {
    const { error: e } = await svc.from("pending_invites").delete().eq("email", parentEmail);
    if (e) console.error("invite cleanup failed:", e.code ?? "unknown");
  };
  const dropUser = async (id: string) => {
    const { error: e } = await svc.auth.admin.deleteUser(id);
    if (e) console.error("orphan user cleanup failed for", id, e.status ?? "unknown");
  };
  const claim = async (id: string, token: string): Promise<boolean> => {
    const { data: ok, error: e } = await svc.rpc("claim_parent_invite", { p_user: id, p_token: token });
    if (e) console.error("claim rpc failed:", e.code ?? "unknown");
    return ok === true;
  };

  if (row.invite_token) {
    const token = row.invite_token;
    const { data: s } = await svc.from("student_details")
      .select("signup_parent_name").eq("profile_id", studentId).maybeSingle();
    const full = (s?.signup_parent_name ?? "").trim();
    const space = full.indexOf(" ");
    const first = space === -1 ? full : full.slice(0, space);
    const last = space === -1 ? "" : full.slice(space + 1).trim();

    const { data: created, error: cErr } = await svc.auth.admin.createUser({
      email: parentEmail,
      email_confirm: true,
      app_metadata: { invite_token: token },
      user_metadata: { first_name: first, last_name: last },
    });

    if (!cErr && created.user) {
      // GoTrue writes app_metadata after the insert, so the sign-up trigger cannot apply the invite.
      if (await claim(created.user.id, token)) {
        parentId = created.user.id;
        parentInvited = true;
      } else {
        console.error("parent invite claim failed");
        await dropUser(created.user.id);
        await dropInvite();
        parentId = null;
      }
    } else if (cErr) {
      console.error("parent createUser failed:", cErr.status ?? "unknown", cErr.code ?? "unknown");
      // Another approval (or a crashed earlier one) may own this account: heal it if it carries this invite.
      const { data: existing } = await svc.from("profiles").select("id, role")
        .eq("email", parentEmail).maybeSingle();
      let mine = existing?.role === "parent";
      if (existing && !mine) {
        const { data: au } = await svc.auth.admin.getUserById(existing.id);
        const tok = au?.user?.app_metadata?.invite_token;
        const age = au?.user ? Date.now() - new Date(au.user.created_at).getTime() : Infinity;
        // GoTrue writes app_metadata after the insert: a very fresh shell without a token yet is the
        // concurrent request mid-creation. The claim (retried below) is the real gate.
        mine = tok === token || (tok === undefined && age < 60_000 && existing.role === "student");
      }
      if (existing && mine) {
        const wasShell = existing.role !== "parent";
        let ok = false;
        for (let i = 0; i < 5 && !ok; i++) {
          ok = await claim(existing.id, token);
          if (!ok) await new Promise((r) => setTimeout(r, 200));
        }
        if (ok) {
          parentId = existing.id;
          parentInvited = wasShell; // healed orphan never got its invite email
        } else {
          console.error("could not claim existing parent account");
          parentId = null;
        }
        // The invite is never deleted in this branch.
      } else {
        await dropInvite();
        if (/already|registered|exists/i.test(cErr.message)) warning = "email_in_use";
        parentId = null;
      }
    }

    if (parentId) {
      const { error: lErr } = await svc.from("parent_children")
        .upsert({ parent_id: parentId, student_id: studentId }, { onConflict: "parent_id,student_id", ignoreDuplicates: true });
      if (lErr) console.error("parent link failed:", lErr.code ?? "unknown");
      else linked = true;
      if (parentInvited) {
        const { error: mErr } = await svc.auth.admin.updateUserById(parentId, { app_metadata: { invite_token: null } });
        if (mErr) console.error("invite token clear failed:", mErr.status ?? "unknown");
      }
    }
  }

  let emailsSent = true;

  if (parentInvited && parentId) {
    let sent = false;
    const { data: link } = await svc.auth.admin.generateLink({ type: "recovery", email: parentEmail });
    const actionLink = link?.properties?.action_link;
    if (actionLink) sent = await sendEmail(parentEmail, "invite", { link: actionLink });
    if (sent) {
      const { error: iErr } = await svc.from("profiles")
        .update({ invite_sent_at: new Date().toISOString() }).eq("id", parentId);
      if (iErr) console.error("invite_sent_at update failed:", iErr.code ?? "unknown");
    } else {
      emailsSent = false;
    }
  }

  const { data: student } = await svc.from("profiles").select("email, first_name").eq("id", studentId).maybeSingle();
  if (student?.email) {
    const ok = await sendEmail(String(student.email), "approved", {
      index_number: row.index_number,
      name: student.first_name ?? "",
    });
    if (!ok) emailsSent = false;
  } else {
    emailsSent = false;
  }

  const result: Record<string, unknown> = {
    indexNumber: row.index_number,
    parentInvited,
    parentLinked: linked,
    emailsSent,
  };
  if (warning) result.warning = warning;
  return jsonResponse(result);
}));
