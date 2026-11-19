import Link from "next/link";
import { AppShell } from "@/components/AppShell";
import { ScanCheck } from "@/components/papers/ScanCheck";

export default function ScanCheckPage() {
  return (
    <AppShell role="admin" title="Check a scan">
      <div className="space-y-4">
        <Link href="/admin/exams" className="text-sm text-blue-700 underline">
          Back to exams
        </Link>
        <ScanCheck />
      </div>
    </AppShell>
  );
}
