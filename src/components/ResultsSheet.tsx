"use client";

import { useState } from "react";
// Mockup: the sent state lives in the page only. It does not email anyone yet.
export function SendToParentButton({ parentEmail, initialSent = false, sentDate }: { parentEmail: string; initialSent?: boolean; sentDate?: string }) {
  const [sent, setSent] = useState(initialSent);
  const [date, setDate] = useState(sentDate);

  if (sent) {
    return (
      <span className="inline-flex items-center gap-2 text-sm text-green-700">
        <span className="rounded-full bg-green-100 px-2.5 py-1 text-xs font-medium">Sent {date ?? "today"}</span>
        <span className="text-xs text-slate-500">to {parentEmail}</span>
      </span>
    );
  }

  return (
    <button
      type="button"
      onClick={() => {
        setSent(true);
        setDate("just now");
      }}
      className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
    >
      Send to parent
    </button>
  );
}

export function PrintButton() {
  return (
    <button
      type="button"
      onClick={() => window.print()}
      className="rounded-lg border border-blue-600 px-4 py-2 text-sm font-medium text-blue-700 hover:bg-blue-50 print:hidden"
    >
      Print sheet
    </button>
  );
}
