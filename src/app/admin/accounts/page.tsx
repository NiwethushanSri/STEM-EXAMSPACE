import { AppShell, Card, Table, Badge } from "@/components/AppShell";
import { accounts, pendingApprovals } from "@/lib/site-data";

export default function AdminAccounts() {
  return (
    <AppShell role="admin" title="Accounts">
      <div className="mb-4 flex justify-end">
        <button className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700">
          Create account
        </button>
      </div>
      <Card title="All accounts">
        <Table
          head={["Name", "Role", "Status"]}
          rows={accounts.map((a) => [
            a.name,
            a.role,
            <Badge key={a.name} tone={a.status === "Active" ? "green" : "red"}>{a.status}</Badge>,
          ])}
        />
      </Card>
      <div className="mt-6">
        <Card title="Register and approve students">
          <Table
            head={["Name", "School", "Submitted", "Action"]}
            rows={pendingApprovals.map((p) => [
              p.name,
              p.school,
              p.submitted,
              <span key={p.name} className="text-blue-700 underline">Review</span>,
            ])}
          />
        </Card>
      </div>
    </AppShell>
  );
}
