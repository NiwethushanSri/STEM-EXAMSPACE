import { AppShell, Card, Table, Badge } from "@/components/AppShell";
import { bookings } from "@/lib/site-data";

export default function AdminBookings() {
  return (
    <AppShell role="admin" title="Bookings & payments">
      <Card title="Bookings">
        <Table
          head={["Ref", "Student", "Exam", "Amount", "Status"]}
          rows={bookings.map((b) => [
            b.id,
            b.student,
            b.exam,
            b.amount,
            <Badge
              key={b.id}
              tone={b.status === "Paid" ? "green" : b.status === "Pending" ? "amber" : "red"}
            >
              {b.status}
            </Badge>,
          ])}
        />
      </Card>
    </AppShell>
  );
}
