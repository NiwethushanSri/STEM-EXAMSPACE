import { AppShell, Card, Table, Badge } from "@/components/AppShell";
import { attendance, student } from "@/lib/site-data";

export default function AdminAttendance() {
  const notMarked = [
    { student: student.name, exam: "Chemistry Mock 1", date: "20 Sep 2026" },
    { student: "Kasun Silva", exam: "Biology Mock 1", date: "22 Sep 2026" },
  ];
  return (
    <AppShell role="admin" title="Attendance">
      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="Attendance sheet">
          <Table
            head={["Date", "Exam", "Status"]}
            rows={attendance.map((a) => [
              a.date,
              a.exam,
              <Badge key={a.date} tone={a.status === "Present" ? "green" : a.status === "Late" ? "amber" : "red"}>
                {a.status}
              </Badge>,
            ])}
          />
        </Card>
        <Card title="Attendance not marked">
          <Table
            head={["Student", "Exam", "Date"]}
            rows={notMarked.map((n) => [n.student, n.exam, n.date])}
          />
        </Card>
      </div>
    </AppShell>
  );
}
