"use client";

import { useState, useTransition, type FormEvent } from "react";
import { Badge, Card } from "@/components/AppShell";
import { inputClass, labelClass } from "@/components/AuthLayout";
import { saveVenueAction, type VenueActionResult } from "@/app/admin/venues/actions";
import type { VenueOption } from "@/lib/exams-staff";

type Editing = VenueOption | "new" | null;

function VenueForm({
  venue,
  busy,
  error,
  onSubmit,
  onCancel,
}: {
  venue: VenueOption | null;
  busy: boolean;
  error: string | null;
  onSubmit: (v: { id: string; name: string; rooms: string; active: boolean }) => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState(venue?.name ?? "");
  const [rooms, setRooms] = useState((venue?.rooms ?? []).join("\n"));
  const [active, setActive] = useState(venue?.active ?? true);
  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    onSubmit({ id: venue?.id ?? "", name, rooms, active });
  }
  return (
    <form onSubmit={submit} aria-label={venue ? "Edit venue" : "New venue"} className="space-y-4 rounded-lg border border-blue-200 bg-white p-5 shadow-sm">
      <h2 className="text-sm font-semibold text-blue-800">{venue ? "Edit venue" : "New venue"}</h2>
      {error && (
        <p role="alert" className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</p>
      )}
      <div className="grid gap-4 sm:grid-cols-2">
        <div>
          <label htmlFor="v-name" className={labelClass}>Venue name</label>
          <input id="v-name" value={name} onChange={(e) => setName(e.target.value)} maxLength={80} className={inputClass} required />
          <label className="mt-3 flex items-center gap-2 text-sm text-slate-700">
            <input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} />
            Active (can be chosen for new exams)
          </label>
        </div>
        <div>
          <label htmlFor="v-rooms" className={labelClass}>Rooms (one per line)</label>
          <textarea id="v-rooms" rows={4} value={rooms} onChange={(e) => setRooms(e.target.value)} className={inputClass} />
          <p className="mt-1 text-xs text-slate-500">Press Enter between rooms. Commas are part of a room name.</p>
        </div>
      </div>
      <div className="flex justify-end gap-2">
        <button type="button" onClick={onCancel} disabled={busy} className="rounded border border-slate-300 px-4 py-2 text-sm hover:bg-slate-50 disabled:opacity-60">Close</button>
        <button type="submit" disabled={busy} className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60">
          {busy ? "Saving..." : venue ? "Save venue" : "Add venue"}
        </button>
      </div>
    </form>
  );
}

/** The admin venues screen: list with rooms and active state, add and edit. */
export function VenuesManager({ venues }: { venues: VenueOption[] }) {
  const [editing, setEditing] = useState<Editing>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [, startTransition] = useTransition();

  function save(v: { id: string; name: string; rooms: string; active: boolean }) {
    setBusy(true);
    setFormError(null);
    setNotice(null);
    startTransition(async () => {
      let res: VenueActionResult;
      try {
        res = await saveVenueAction(v);
      } catch {
        res = { ok: false, message: "Something went wrong. Please try again." };
      }
      setBusy(false);
      if (res.ok) {
        setEditing(null);
        setNotice(res.message);
      } else {
        setFormError(res.message);
      }
    });
  }

  return (
    <div className="space-y-5">
      {notice && <div role="status" className="rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-900">{notice}</div>}
      <div className="flex justify-end">
        <button
          type="button"
          onClick={() => {
            setFormError(null);
            setNotice(null);
            setEditing("new");
          }}
          className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
        >
          New venue
        </button>
      </div>
      {editing && (
        <VenueForm
          key={editing === "new" ? "new" : editing.id}
          venue={editing === "new" ? null : editing}
          busy={busy}
          error={formError}
          onSubmit={save}
          onCancel={() => setEditing(null)}
        />
      )}
      <Card title="Venues">
        {venues.length === 0 ? (
          <p className="text-sm text-slate-500">No venues yet. Add one before creating an in-person exam.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-left text-sm">
              <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  {["Venue", "Rooms", "Status", "Actions"].map((h) => (
                    <th key={h} className="py-2 pr-4 font-medium">{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {venues.map((v) => (
                  <tr key={v.id} data-testid="venue-row" className="border-b border-slate-100 last:border-0">
                    <td className="py-2.5 pr-4 font-medium text-slate-900">{v.name}</td>
                    <td className="py-2.5 pr-4">{v.rooms.length ? v.rooms.join(", ") : <span className="text-slate-400">No rooms</span>}</td>
                    <td className="py-2.5 pr-4"><Badge tone={v.active ? "green" : "slate"}>{v.active ? "Active" : "Inactive"}</Badge></td>
                    <td className="py-2.5">
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => {
                          setFormError(null);
                          setNotice(null);
                          setEditing(v);
                        }}
                        className="rounded border border-slate-300 px-3 py-1 text-xs hover:bg-slate-50 disabled:opacity-60"
                      >
                        Edit
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>
    </div>
  );
}
