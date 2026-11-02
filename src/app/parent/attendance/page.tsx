import { AppShell, Card, Table, Badge } from "@/components/AppShell";
import { attendance } from "@/lib/site-data";

export default function ParentAttendance() {
  return (
    <AppShell role="parent" title="Attendance record">
      <Card title="Exam attendance">
        <Table
          head={["Date", "Exam", "Status"]}
          rows={attendance.map((a) => [
            a.date,
            a.exam,
            <Badge
              key={a.date}
              tone={a.status === "Present" ? "green" : a.status === "Late" ? "amber" : "red"}
            >
              {a.status}
            </Badge>,
          ])}
        />
      </Card>
    </AppShell>
  );
}
