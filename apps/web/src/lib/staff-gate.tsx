import { Suspense, type ReactNode } from "react";
import { redirect } from "next/navigation";
import { homeFor, roleLabel, type AppRole } from "@stem/shared";
import { ShellUserProvider } from "@/components/AppShell";
import { getSessionProfile, type SessionProfile } from "@/lib/supabase/server";

/**
 * The real authorisation check, read from the database on every call: the caller must hold one of
 * `roles` AND be active. Anything else redirects. Call it inside every data loader before any query and
 * at the top of every staff page (layouts do not gate pages; a page can render without its layout).
 */
export async function requireStaff(roles: readonly AppRole[]): Promise<SessionProfile> {
  const me = await getSessionProfile();
  if (!me || me.status === "unconfirmed") redirect("/login");
  if (me.status === "suspended") redirect("/account/suspended");
  if (!roles.includes(me.role)) redirect(homeFor(me.role, me.status, "web-staff"));
  if (me.status !== "active") redirect("/login");
  return me;
}

/** Layout body for a staff area: waits for the role check (a real redirect for the wrong role) and gives AppShell the user. */
export async function StaffLayout({ allowed, children }: { allowed: readonly AppRole[]; children: ReactNode }) {
  const me = await requireStaff(allowed);
  return (
    <ShellUserProvider user={{ name: `${me.firstName} ${me.lastName}`.trim(), roleLabel: roleLabel(me.role) }}>
      {children}
    </ShellUserProvider>
  );
}

/** Page-level guard for pages with no data loader of their own. Wrap in Suspense (it reads the session). */
export function GuardedPage({ roles, children }: { roles: readonly AppRole[]; children: ReactNode }) {
  return (
    <Suspense fallback={null}>
      <Guard roles={roles}>{children}</Guard>
    </Suspense>
  );
}

async function Guard({ roles, children }: { roles: readonly AppRole[]; children: ReactNode }) {
  await requireStaff(roles);
  return <>{children}</>;
}
