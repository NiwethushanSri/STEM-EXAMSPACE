import { AppShell, Card, Table, Badge } from "@/components/AppShell";

const seeds = [
  { id: "6160354608", marks: 76, diff: 1, status: "In tolerance" },
  { id: "6158022422", marks: 22, diff: 5, status: "Inaccurate" },
  { id: "6155333039", marks: 55, diff: 4, status: "In tolerance" },
  { id: "6156742986", marks: 80, diff: 3, status: "In tolerance" },
  { id: "6159055876", marks: 81, diff: 6, status: "Inaccurate" },
];

export default function Standardisation() {
  return (
    <AppShell role="examiner" title="Standardisation">
      <Card title="Seed responses">
        <Table
          head={["Response", "Marks", "Absolute difference", "Accuracy"]}
          rows={seeds.map((s) => [
            s.id,
            s.marks,
            s.diff,
            <Badge key={s.id} tone={s.status === "In tolerance" ? "green" : "red"}>{s.status}</Badge>,
          ])}
        />
      </Card>
    </AppShell>
  );
}
