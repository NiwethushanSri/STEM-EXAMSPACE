import { AppShell, Card, Table } from "@/components/AppShell";
import { results } from "@/lib/site-data";

export default function ParentResults() {
  return (
    <AppShell role="parent" title="Child's results and feedback">
      <Card title="Results by subject">
        <Table
          head={["Subject", "Test", "Mark", "Class avg", "High", "Low", "Weak areas"]}
          rows={results.map((r) => [
            r.subject,
            r.test,
            `${r.mark}%`,
            `${r.classAverage}%`,
            `${r.highest}%`,
            `${r.lowest}%`,
            r.weakAreas.length ? r.weakAreas.join(", ") : "None",
          ])}
        />
      </Card>
      <p className="mt-4 text-sm text-slate-500">
        Feedback appears here once all of a student's papers are marked.
      </p>
    </AppShell>
  );
}
