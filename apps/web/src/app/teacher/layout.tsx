export const instant = false;

import type { ReactNode } from "react";
import { StaffLayout } from "@/lib/staff-gate";

export default function Layout({ children }: { children: ReactNode }) {
  return <StaffLayout allowed={["teacher"]}>{children}</StaffLayout>;
}
