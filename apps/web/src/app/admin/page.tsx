import { AppShell } from "@/components/AppShell";
import { AccountsOverview } from "@/components/accounts/AccountsSection";

export default function AdminDashboard() {
  return (
    <AppShell role="admin" title="Admin dashboard">
      <AccountsOverview accountsHref="/admin/accounts" />
    </AppShell>
  );
}
