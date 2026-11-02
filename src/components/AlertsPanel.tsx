"use client";

import { useEffect, useState } from "react";
import { Card, Badge } from "@/components/AppShell";
import { getAlerts, runReminders, type Alert } from "@/lib/alerts";

const KIND_LABEL: Record<Alert["kind"], string> = {
  notice: "Notice",
  "exam-update": "Calendar change",
  reminder: "Reminder",
};

// Alerts for one audience (student or parent) of one child, newest first.
export function AlertsPanel({ audience, childId }: { audience: Alert["audience"]; childId: string }) {
  const [alerts, setAlerts] = useState<Alert[]>([]);

  useEffect(() => {
    runReminders();
    setAlerts(getAlerts().filter((a) => a.audience === audience && a.childId === childId));
  }, [audience, childId]);

  return (
    <Card title="Alerts">
      {alerts.length === 0 ? (
        <p className="py-4 text-center text-sm text-slate-500">No alerts yet.</p>
      ) : (
        <ul className="divide-y divide-slate-100 text-sm">
          {alerts.map((a) => (
            <li key={a.id} className="py-3">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <div className="font-medium">{a.title}</div>
                  <div className="mt-0.5 text-slate-600">{a.body}</div>
                </div>
                <Badge tone={a.kind === "reminder" ? "amber" : a.kind === "exam-update" ? "blue" : "red"}>{KIND_LABEL[a.kind]}</Badge>
              </div>
              <div className="mt-1 text-xs text-slate-500">
                {new Date(a.createdAt).toLocaleString("en-GB", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })}
              </div>
            </li>
          ))}
        </ul>
      )}
    </Card>
  );
}
