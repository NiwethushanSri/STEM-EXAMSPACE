import { AppShell, Card, Table, Badge } from "@/components/AppShell";
import { paperAllocations } from "@/lib/site-data";

export default function AdminPapers() {
  return (
    <AppShell role="admin" title="Paper allocation">
      <Card title="Allocations (physical and online)">
        <Table
          head={["Paper", "Mode", "Examiner", "Papers", "Marked", "Progress"]}
          rows={paperAllocations.map((p) => [
            p.paper,
            <Badge key={p.paper} tone={p.mode === "Online" ? "blue" : "amber"}>{p.mode}</Badge>,
            p.examiner,
            p.papers,
            p.marked,
            `${Math.round((p.marked / p.papers) * 100)}%`,
          ])}
        />
      </Card>
    </AppShell>
  );
}
