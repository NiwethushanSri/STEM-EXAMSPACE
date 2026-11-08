import { AppShell } from "@/components/AppShell";
import { AccountsSection, type SearchParams } from "@/components/accounts/AccountsSection";

export default function OwnerStaff({ searchParams }: { searchParams: SearchParams }) {
  return (
    <AppShell role="owner" title="Staff">
      <AccountsSection mode="staff" roles={["owner"]} searchParams={searchParams} />
    </AppShell>
  );
}
