import { AppShell, Card, Table, Badge, Stat } from "@/components/AppShell";
import { examinerProgress, paperAllocations } from "@/lib/site-data";

export default function AdminMarking() {
  const total = paperAllocations.reduce((s, p) => s + p.papers, 0);
  const done = paperAllocations.reduce((s, p) => s + p.marked, 0);
  return (
    <AppShell role="admin" title="Marking progress">
      <div className="grid gap-4 md:grid-cols-3">
        <Stat label="Papers marked" value={`${done} / ${total}`} />
        <Stat label="Examiners" value={examinerProgress.length} />
        <Stat label="Feedback ready" value={done === total ? "Yes" : "No"} />
      </div>
      <div className="mt-6">
        <Card title="Per examiner">
          <Table
            head={["Examiner", "Assigned", "Marked", "Accuracy"]}
            rows={examinerProgress.map((e) => [
              e.name,
              e.assigned,
              e.marked,
              <Badge key={e.name} tone={e.accuracy === "In tolerance" ? "green" : "red"}>{e.accuracy}</Badge>,
            ])}
          />
        </Card>
      </div>
    </AppShell>
  );
}
