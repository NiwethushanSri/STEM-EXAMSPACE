import { requireCaller, serviceClient } from "../_shared/auth.ts";
import { HttpError, handle, jsonResponse } from "../_shared/errors.ts";
import { sendEmail } from "../_shared/email.ts";
import { writeAudit } from "../_shared/audit.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
  // Locks the profile, re-checks student/pending/not-a-claim-shell, deletes, returns the address.
  const { data, error } = await svc.rpc("reject_student_tx", { p_student: studentId });
  if (error) {
    if (error.code === "P0001" && error.message === "not_found") {
      throw new HttpError("not_found", 404, "Student not found.");
    }
    if (error.code === "P0001" && error.message === "conflict") {
      throw new HttpError("conflict", 409, "This registration was already handled.");
    }
    console.error("reject_student_tx failed:", error.code ?? "unknown");
    throw new HttpError("internal", 500, "Something went wrong. Please try again.");
  }
  const email = typeof data === "string" ? data : "";

  // The account is gone. The email is best effort and never fails the request.
  const emailSent = email ? await sendEmail(email, "rejected", {}) : false;

  await writeAudit(caller.id, "registration_rejected");
  return jsonResponse({ emailSent });
}));
