export const instant = false;

import type { ReactNode } from "react";
import { MARKING_ROLES } from "@/lib/marking-lists";
import { StaffLayout } from "@/lib/staff-gate";

/** Only the gate (Ruling R2): each page draws its own frame. The marker home wraps itself in the staff shell; the
 * marking screen fills the whole screen with no side menu. */
export default function Layout({ children }: { children: ReactNode }) {
  return <StaffLayout allowed={MARKING_ROLES}>{children}</StaffLayout>;
}
