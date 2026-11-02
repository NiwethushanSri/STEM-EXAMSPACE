"use client";

import { useEffect, useState } from "react";
import { AppShell, Card, Badge } from "@/components/AppShell";
import { getNotices, type Notice } from "@/lib/alerts";

export default function ParentNotices() {
  const [special, setSpecial] = useState<Notice[]>([]);

  useEffect(() => {
    setSpecial(getNotices().filter((n) => n.type === "Special notice"));
  }, []);

  return (
    <AppShell role="parent" title="Special notices">
      <div className="space-y-4">
        {special.map((n) => (
          <Card key={n.id}>
            <div className="flex items-start justify-between gap-4">
              <div>
                <h2 className="font-semibold">{n.title}</h2>
                <p className="mt-1 text-sm text-slate-600">{n.body}</p>
              </div>
              <Badge tone="red">Special</Badge>
            </div>
            <div className="mt-3 text-xs text-slate-500">{n.date}</div>
          </Card>
        ))}
      </div>
    </AppShell>
  );
}
