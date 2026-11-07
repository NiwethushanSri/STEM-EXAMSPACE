import { AppShell, Card, Table } from "@/components/AppShell";
import { auditLog } from "@/lib/site-data";

export default function AdminAudit() {
  return (
    <AppShell role="admin" title="Audit log">
      <Card title="Recent actions">
        <Table
          head={["Time", "User", "Action", "Target"]}
          rows={auditLog.map((a) => [a.time, a.user, a.action, a.target])}
        />
      </Card>
    </AppShell>
  );
}
