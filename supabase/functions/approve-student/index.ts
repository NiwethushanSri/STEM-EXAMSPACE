import { requireCaller, serviceClient } from "../_shared/auth.ts";
import { HttpError, handle, jsonResponse } from "../_shared/errors.ts";
import { sendEmail } from "../_shared/email.ts";
import { clearInviteToken, linkParent, provisionInvitedUser, sendInviteEmail } from "../_shared/invite.ts";

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
  let linked = false;
  let warning: string | undefined;

  if (row.invite_token) {
    const token = row.invite_token;
    const { data: s } = await svc.from("student_details")
      .select("signup_parent_name").eq("profile_id", studentId).maybeSingle();
    const full = (s?.signup_parent_name ?? "").trim();
    const space = full.indexOf(" ");
    const first = space === -1 ? full : full.slice(0, space);
    const last = space === -1 ? "" : full.slice(space + 1).trim();

    const res = await provisionInvitedUser(svc, {
      email: parentEmail,
      token,
      role: "parent",
      firstName: first,
      lastName: last,
    });
    parentId = res.userId;
    parentInvited = res.invited;
    if (res.warning) warning = res.warning;
  }

  if (parentId) {
    const lr = await linkParent(svc, parentId, studentId);
    linked = lr === "linked" || lr === "exists";
    if (lr === "parent_inactive") warning = "parent_suspended";
    if (parentInvited) await clearInviteToken(svc, parentId);
  }

  let emailsSent = true;

  if (parentInvited && parentId) {
    if (!(await sendInviteEmail(svc, parentId, parentEmail))) emailsSent = false;
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
