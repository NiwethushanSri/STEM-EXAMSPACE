import { serviceClient } from "./auth.ts";

/** Records an audit row with the service role. Failures are logged and rethrown, never swallowed. */
export async function writeAudit(
  actorId: string | null,
  action: string,
  targetType?: string,
  targetId?: string,
): Promise<void> {
  const { error } = await serviceClient().from("audit_log").insert({
    actor_id: actorId,
    action,
    target_type: targetType ?? null,
    target_id: targetId ?? null,
  });
  if (error) {
    console.error("audit write failed:", error.message);
    throw new Error(`audit write failed: ${error.message}`);
  }
}
