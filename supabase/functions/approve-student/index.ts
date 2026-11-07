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

function mapTxError(message: string): HttpError {
  switch (message) {
    case "conflict":
      return new HttpError("conflict", 409, "This registration was already handled.");
    case "parent_email_is_staff":
      return new HttpError(
        "parent_email_is_staff",
        409,
        "The parent email belongs to a staff account. Edit the parent email first.",
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
    if (error.code === "P0001") throw mapTxError(error.message);
    console.error("approve_student_tx failed:", error.code ?? "unknown");
    throw new HttpError("internal", 500, "Something went wrong. Please try again.");
  }
  const row = (Array.isArray(data) ? data[0] : data) as TxRow | undefined;
  if (!row) throw new HttpError("internal", 500, "Something went wrong. Please try again.");

  // The approval is committed. Everything below is best effort and never fails the request.
  const parentEmail = row.parent_email;
  let parentInvited = false;
  let warning: string | undefined;
  let parentId = row.parent_id;

  if (row.invite_token) {
    const { data: s } = await svc.from("student_details")
      .select("signup_parent_name").eq("profile_id", studentId).maybeSingle();
    const full = (s?.signup_parent_name ?? "").trim();
    const space = full.indexOf(" ");
    const first = space === -1 ? full : full.slice(0, space);
    const last = space === -1 ? "" : full.slice(space + 1).trim();

    const { data: created, error: cErr } = await svc.auth.admin.createUser({
      email: parentEmail,
      email_confirm: true,
      app_metadata: { invite_token: row.invite_token },
      user_metadata: { first_name: first, last_name: last },
    });

    // GoTrue writes app_metadata after the insert, so the sign-up trigger cannot apply the
    // invite itself; claim it explicitly (service role only, token must match).
    let claimed = false;
    if (!cErr && created.user) {
      const { data: ok } = await svc.rpc("claim_parent_invite", {
        p_user: created.user.id,
        p_token: row.invite_token,
      });
      claimed = ok === true;
      if (!claimed) {
        await svc.auth.admin.deleteUser(created.user.id);
        await svc.from("pending_invites").delete().eq("email", parentEmail);
        console.error("parent invite claim failed");
      }
    }

    if (claimed && created.user) {
      parentId = created.user.id;
      parentInvited = true;
    } else if (!cErr) {
      parentId = null;
    } else {
      // A concurrent approval may have just created this parent; link to it if so.
      const { data: existing } = await svc.from("profiles").select("id, role")
        .eq("email", parentEmail).maybeSingle();
      if (existing?.role === "parent") {
        parentId = existing.id;
      } else {
        // Drop the unused invite so it cannot attach to a later sign-up.
        await svc.from("pending_invites").delete().eq("email", parentEmail);
        if (cErr && /already|registered|exists/i.test(cErr.message)) warning = "email_in_use";
        console.error("parent createUser failed");
      }
    }

    if (parentId) {
      const { error: lErr } = await svc.from("parent_children")
        .upsert({ parent_id: parentId, student_id: studentId }, { onConflict: "parent_id,student_id", ignoreDuplicates: true });
      if (lErr) console.error("parent link failed:", lErr.code ?? "unknown");
    }
  }

  let emailsSent = true;

  if (parentInvited && parentId) {
    let sent = false;
    const { data: link } = await svc.auth.admin.generateLink({ type: "recovery", email: parentEmail });
    const actionLink = link?.properties?.action_link;
    if (actionLink) sent = await sendEmail(parentEmail, "invite", { link: actionLink });
    if (sent) {
      await svc.from("profiles").update({ invite_sent_at: new Date().toISOString() }).eq("id", parentId);
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

  const result: Record<string, unknown> = { indexNumber: row.index_number, parentInvited, emailsSent };
  if (warning) result.warning = warning;
  return jsonResponse(result);
}));
