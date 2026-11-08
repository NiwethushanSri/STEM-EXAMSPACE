import { AppShell } from "@/components/AppShell";
import { AccountsSection } from "@/components/accounts/AccountsSection";

export default function OwnerStaff() {
  return (
    <AppShell role="owner" title="Staff">
      <AccountsSection mode="staff" />
    </AppShell>
  );
}
