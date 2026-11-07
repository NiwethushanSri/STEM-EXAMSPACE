import { AppShell, Card, Table } from "@/components/AppShell";
import { results } from "@/lib/site-data";

export default function StudentResults() {
  return (
    <AppShell role="student" title="Results">
      <Card title="Marks by subject">
        <Table
          head={["Subject", "Test", "Your mark", "Class avg", "High", "Low", "Date"]}
          rows={results.map((r) => [
            r.subject,
            r.test,
            <span key={r.subject} className="font-semibold">{r.mark}%</span>,
            `${r.classAverage}%`,
            `${r.highest}%`,
            `${r.lowest}%`,
            r.date,
          ])}
        />
      </Card>

      <div className="mt-6 grid gap-4 md:grid-cols-2">
        {results.map((r) => (
          <Card key={r.subject} title={`${r.subject} · weak areas`}>
            {r.weakAreas.length === 0 ? (
              <p className="text-sm text-slate-500">No weak areas identified in this test.</p>
            ) : (
              <ul className="list-disc space-y-1 pl-5 text-sm">
                {r.weakAreas.map((w) => (
                  <li key={w}>{w}</li>
                ))}
              </ul>
            )}
            <div className="mt-4 text-xs text-slate-500">Examiner comment: feedback sent after all papers are marked.</div>
          </Card>
        ))}
      </div>
    </AppShell>
  );
}
