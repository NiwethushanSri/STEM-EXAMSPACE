import { AppShell } from "@/components/AppShell";
import { AccountsSection } from "@/components/accounts/AccountsSection";

export default function OwnerAccounts() {
  return (
    <AppShell role="owner" title="Accounts">
      <AccountsSection mode="all" />
    </AppShell>
  );
}
