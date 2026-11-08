import { Suspense, type ReactNode } from "react";
import { redirect } from "next/navigation";
import { homeFor, roleLabel, type AppRole } from "@stem/shared";
import { ShellUserProvider } from "@/components/AppShell";
import { getSessionProfile, type SessionProfile } from "@/lib/supabase/server";

/**
 * The real server-side check for a staff area (the proxy only checks optimistically): the database must
 * say the caller is active and one of `allowed`. Redirects otherwise.
 */
export async function requireStaff(allowed: readonly AppRole[]): Promise<SessionProfile> {
  const me = await getSessionProfile();
  if (!me || me.status === "unconfirmed") redirect("/login");
  if (me.status === "suspended") redirect("/account/suspended");
  if (me.status !== "active" || !allowed.includes(me.role)) {
    const home = homeFor(me.role, me.status, "web-staff");
    redirect(allowed.includes(me.role) ? "/login" : home);
  }
  return me;
}

async function Gate({ allowed, children }: { allowed: readonly AppRole[]; children: ReactNode }) {
  const me = await requireStaff(allowed);
  return (
    <ShellUserProvider user={{ name: `${me.firstName} ${me.lastName}`.trim(), roleLabel: roleLabel(me.role) }}>
      {children}
    </ShellUserProvider>
  );
}

/** Layout body for a staff area: guards by role and gives AppShell the signed-in user. */
export function StaffLayout({ allowed, children }: { allowed: readonly AppRole[]; children: ReactNode }) {
  return (
    <Suspense fallback={null}>
      <Gate allowed={allowed}>{children}</Gate>
    </Suspense>
  );
}
