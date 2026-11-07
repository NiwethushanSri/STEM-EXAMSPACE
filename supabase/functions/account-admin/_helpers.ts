import { decodeBase64 } from "jsr:@std/encoding@1/base64";
import { anon, createTestUser, deleteUserIds, deleteUsers, env, service, type TestUser } from "../_shared/test_helpers.ts";

// Shared setup for the account-admin test files (not itself a test file).
export { anon, createTestUser, deleteUserIds, deleteUsers, env, service };
export type { TestUser };

export type Svc = ReturnType<typeof service>;

export async function post(fn: string, token: string, body: unknown): Promise<{ status: number; json: any }> {
  const res = await fetch(`${env("SUPABASE_URL")}/functions/v1/${fn}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      apikey: env("SUPABASE_ANON_KEY"),
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  return { status: res.status, json: await res.json().catch(() => null) };
}
export const resend = (token: string, userId: string) => post("account-admin", token, { action: "resend_invite", userId });

/** A pending student with signup parent details (approve-student turns it into an approved one). */
export async function pendingStudent(svc: Svc, parentEmail: string): Promise<TestUser> {
  const u = await createTestUser(svc, { role: "student", status: "pending" });
  const { error } = await svc.from("student_details").update({
    signup_parent_name: "Kamal Perera",
    signup_parent_email: parentEmail,
  }).eq("profile_id", u.id);
  if (error) {
    await deleteUsers(svc, [u]);
    throw new Error(`student_details update failed: ${error.message}`);
  }
  return u;
}

export async function withScenario(fn: (ctx: {
  svc: Svc;
  track: (u: TestUser) => TestUser;
  parentEmail: string;
}) => Promise<void>) {
  const svc = service();
  const users: TestUser[] = [];
  const parentEmail = `t10a-parent-${crypto.randomUUID()}@example.test`;
  try {
    await fn({ svc, track: (u) => (users.push(u), u), parentEmail });
  } finally {
    const { data, error: selErr } = await svc.from("profiles").select("id").eq("email", parentEmail);
    const { error: invErr } = await svc.from("pending_invites").delete().eq("email", parentEmail);
    const extra = (data ?? []).map((r: { id: string }) => r.id);
    await deleteUsers(svc, users);
    await deleteUserIds(svc, extra);
    if (selErr || invErr) throw new Error(`test cleanup query failed: ${selErr?.code ?? ""} ${invErr?.code ?? ""}`);
  }
}

export async function markApproved(svc: Svc, id: string, index: string) {
  const { error: e1 } = await svc.from("student_details").update({ index_number: index }).eq("profile_id", id);
  const { error: e2 } = await svc.from("profiles").update({ status: "profile_incomplete" }).eq("id", id);
  if (e1 || e2) throw new Error("markApproved failed");
}


export const approvedIndex = () => `SE-2098-${String(Math.floor(Math.random() * 9000) + 1000)}`;

export const act = (token: string, action: string, userId: string) => post("account-admin", token, { action, userId });
export const userGone = async (svc: Svc, id: string) => {
  const { data } = await svc.from("profiles").select("id").eq("id", id);
  const { data: au } = await svc.auth.admin.getUserById(id);
  return (data ?? []).length === 0 && !au?.user;
};
export async function withPassword(svc: Svc, u: TestUser): Promise<string> {
  const password = `Pw-${crypto.randomUUID()}`;
  const { error } = await svc.auth.admin.updateUserById(u.id, { password });
  if (error) throw new Error(`set password failed: ${error.message}`);
  return password;
}
export const status = async (svc: Svc, id: string) =>
  (await svc.from("profiles").select("status").eq("id", id).single()).data!.status;

export const BUCKET = "student-photos";
export const JPEG = decodeBase64(
  "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=",
);
