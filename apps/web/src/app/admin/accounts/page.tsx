import { AppShell } from "@/components/AppShell";
import { AccountsSection, type SearchParams } from "@/components/accounts/AccountsSection";

export default function AdminAccounts({ searchParams }: { searchParams: SearchParams }) {
  return (
    <AppShell role="admin" title="Accounts">
      <AccountsSection mode="all" roles={["admin", "owner"]} searchParams={searchParams} />
    </AppShell>
  );
}
