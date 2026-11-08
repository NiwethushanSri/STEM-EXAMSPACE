import { AppShell } from "@/components/AppShell";
import { AccountsSection } from "@/components/accounts/AccountsSection";

export default function AdminAccounts() {
  return (
    <AppShell role="admin" title="Accounts">
      <AccountsSection mode="all" />
    </AppShell>
  );
}
