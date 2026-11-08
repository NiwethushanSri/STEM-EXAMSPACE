import { AppShell } from "@/components/AppShell";
import { AccountsOverview } from "@/components/accounts/AccountsSection";

export default function OwnerPage() {
  return (
    <AppShell role="owner" title="Super administrator">
      <AccountsOverview accountsHref="/owner/accounts" />
    </AppShell>
  );
}
