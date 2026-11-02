import Link from "next/link";
import { AppShell, Card, Table, Badge, Stat } from "@/components/AppShell";
import { SendToParentButton } from "@/components/ResultsSheet";
import { relationOf, average } from "@/lib/results";
import { children } from "@/lib/site-data";

export default function AdminResults() {
  const withResults = children.filter((c) => c.results.length > 0).length;
  return (
    <AppShell role="admin" title="Results sheets">
      <div className="grid gap-4 md:grid-cols-2">
        <Stat label="Students" value={children.length} />
        <Stat label="Sheets ready" value={withResults} />
      </div>

      <div className="mt-6">
        <Card title="Son and daughter results sheets">
          <Table
            head={["Student", "Relation", "Parent", "Year", "Average", "Sheet", "Action"]}
            rows={children.map((c) => [
              <span key={`${c.id}-n`} className="font-medium">{c.name}</span>,
              <Badge key={`${c.id}-r`} tone={relationOf(c) === "Son" ? "blue" : "amber"}>{relationOf(c)}</Badge>,
              c.parent,
              c.grade,
              c.results.length ? `${average(c)}%` : "—",
              <Link key={`${c.id}-s`} href={`/admin/results/${c.id}`} className="text-blue-700 underline">
                Open sheet
              </Link>,
              <SendToParentButton key={`${c.id}-b`} parentEmail={c.parentEmail} />,
            ])}
          />
        </Card>
      </div>
      <p className="mt-4 text-sm text-slate-500">
        Each sheet goes to the parent email on file. Sending is a mockup for now and no email is sent.
      </p>
    </AppShell>
  );
}
