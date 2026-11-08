import { AppShell } from "@/components/AppShell";
import { AccountsSection, type SearchParams } from "@/components/accounts/AccountsSection";

export default function OwnerAccounts({ searchParams }: { searchParams: SearchParams }) {
  return (
    <AppShell role="owner" title="Accounts">
      <AccountsSection mode="all" roles={["owner"]} searchParams={searchParams} />
    </AppShell>
  );
}
