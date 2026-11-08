import type { ReactNode } from "react";
import { StaffLayout } from "@/lib/staff-gate";

export default function Layout({ children }: { children: ReactNode }) {
  return <StaffLayout allowed={["admin", "owner"]}>{children}</StaffLayout>;
}
