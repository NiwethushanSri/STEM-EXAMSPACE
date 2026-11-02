"use client";

import { useEffect, useState, type FormEvent } from "react";
import { AppShell, Card, Badge } from "@/components/AppShell";
import { inputClass, labelClass } from "@/components/AuthLayout";
import { getNotices, publishNotice, type Notice } from "@/lib/alerts";

export default function AdminNotices() {
  const [notices, setNotices] = useState<Notice[]>([]);
  const [open, setOpen] = useState(false);
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [type, setType] = useState<Notice["type"]>("Special notice");
  const [message, setMessage] = useState("");

  useEffect(() => {
    setNotices(getNotices());
  }, []);

  // Publishing saves the notice and alerts every student and parent straight away.
  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    if (!title.trim() || !body.trim()) return;
    const recipients = publishNotice({ title: title.trim(), body: body.trim(), type });
    setNotices(getNotices());
    setTitle("");
    setBody("");
    setOpen(false);
    setMessage(`Alert sent to ${recipients} students and ${recipients} parents.`);
  }

  return (
    <AppShell role="admin" title="Notices">
      <div className="mb-4 flex items-center justify-between gap-3">
        <p className="text-sm text-green-700">{message}</p>
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
        >
          {open ? "Close" : "New notice"}
        </button>
      </div>

      {open && (
        <form onSubmit={submit} className="mb-6 space-y-3 rounded-xl bg-white p-5 shadow-sm">
          <div>
            <label className={labelClass}>Title</label>
            <input value={title} onChange={(e) => setTitle(e.target.value)} className={inputClass} required />
          </div>
          <div>
            <label className={labelClass}>Message</label>
            <textarea value={body} onChange={(e) => setBody(e.target.value)} rows={3} className={inputClass} required />
          </div>
          <div className="flex flex-wrap items-center justify-between gap-3">
            <select value={type} onChange={(e) => setType(e.target.value as Notice["type"])} className={inputClass + " max-w-56"}>
              <option>Special notice</option>
              <option>Latest notice</option>
            </select>
            <button type="submit" className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700">
              Publish and alert students and parents
            </button>
          </div>
        </form>
      )}

      <div className="space-y-4">
        {notices.map((n) => (
          <Card key={n.id}>
            <div className="flex items-start justify-between gap-4">
              <div>
                <h2 className="font-semibold">{n.title}</h2>
                <p className="mt-1 text-sm text-slate-600">{n.body}</p>
                <div className="mt-2 text-xs text-slate-500">{n.date} · Sent to students and parents</div>
              </div>
              <Badge tone={n.type === "Special notice" ? "red" : "slate"}>{n.type}</Badge>
            </div>
          </Card>
        ))}
      </div>
    </AppShell>
  );
}
