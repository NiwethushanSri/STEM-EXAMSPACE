"use client";

import { useState, type FormEvent } from "react";
import { inputClass, labelClass } from "@/components/AuthLayout";
import type { ExamRow, SubjectOption, VenueOption } from "@/lib/exams-staff";
import { utcToLondonParts } from "@/lib/london-time";
import { penceToInput } from "@/lib/money";

/**
 * Create or edit an exam. Times are UK local date and time (converted on the server). Teachers get the
 * same form without a price field. `onSubmit` receives the raw field values.
 */
export function ExamForm({
  withPrice,
  subjects,
  venues,
  exam,
  busy,
  error,
  onSubmit,
  onCancel,
}: {
  withPrice: boolean;
  subjects: SubjectOption[];
  venues: VenueOption[];
  exam: ExamRow | null;
  busy: boolean;
  error: string | null;
  onSubmit: (raw: Record<string, string>) => void;
  onCancel: () => void;
}) {
  const start = exam ? utcToLondonParts(exam.startsAt) : { date: "", time: "" };
  const deadline = exam ? utcToLondonParts(exam.bookingDeadline) : { date: "", time: "" };
  const [f, setF] = useState({
    subject: String(exam?.subjectId ?? subjects[0]?.id ?? ""),
    title: exam?.title ?? "",
    paper: exam?.paper ?? "",
    format: exam?.format ?? "in_person",
    venue: exam?.venueId ?? "",
    room: exam?.room ?? "",
    startDate: start.date,
    startTime: start.time || "09:00",
    duration: String(exam?.durationMinutes ?? 90),
    seats: String(exam?.seatLimit ?? 30),
    price: exam?.pricePence != null ? penceToInput(exam.pricePence) : "",
    deadlineDate: deadline.date,
    deadlineTime: deadline.time || "17:00",
  });
  const set = (k: keyof typeof f) => (e: { target: { value: string } }) => setF((p) => ({ ...p, [k]: e.target.value }));

  // The venue list offers active venues, plus the exam's current one so an edit does not lose it.
  const venueOptions = venues.filter((v) => v.active || v.id === exam?.venueId);
  const chosen = venues.find((v) => v.id === f.venue);
  const rooms = chosen ? [...new Set([...chosen.rooms, ...(f.room && chosen.id === exam?.venueId ? [f.room] : [])])] : [];

  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    onSubmit({ id: exam?.id ?? "", ...f });
  }

  const unconfirmed = withPrice && exam && !exam.priceConfirmed;

  return (
    <form onSubmit={submit} aria-label={exam ? "Edit exam" : "New exam"} className="space-y-4 rounded-lg border border-blue-200 bg-white p-5 shadow-sm">
      <h2 className="text-sm font-semibold text-blue-800">{exam ? "Edit exam" : "New exam"}</h2>
      {error && (
        <p role="alert" className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800">
          {error}
        </p>
      )}
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <div>
          <label htmlFor="ex-subject" className={labelClass}>Subject</label>
          <select id="ex-subject" value={f.subject} onChange={set("subject")} className={inputClass} required>
            {subjects.map((s) => (
              <option key={s.id} value={s.id}>{s.name}</option>
            ))}
          </select>
        </div>
        <div className="lg:col-span-2">
          <label htmlFor="ex-title" className={labelClass}>Title</label>
          <input id="ex-title" value={f.title} onChange={set("title")} maxLength={120} className={inputClass} required />
        </div>
        <div>
          <label htmlFor="ex-paper" className={labelClass}>Paper (optional)</label>
          <input id="ex-paper" value={f.paper} onChange={set("paper")} maxLength={80} className={inputClass} />
        </div>
        <div>
          <label htmlFor="ex-format" className={labelClass}>Format</label>
          <select id="ex-format" value={f.format} onChange={set("format")} className={inputClass}>
            <option value="in_person">In person</option>
            <option value="online">Online</option>
          </select>
        </div>
        {f.format === "in_person" && (
          <>
            <div>
              <label htmlFor="ex-venue" className={labelClass}>Venue</label>
              <select
                id="ex-venue"
                value={f.venue}
                onChange={(e) => setF((p) => ({ ...p, venue: e.target.value, room: "" }))}
                className={inputClass}
                required
              >
                <option value="">Choose a venue</option>
                {venueOptions.map((v) => (
                  <option key={v.id} value={v.id}>{v.active ? v.name : `${v.name} (inactive)`}</option>
                ))}
              </select>
            </div>
            <div>
              <label htmlFor="ex-room" className={labelClass}>Room</label>
              <select id="ex-room" value={f.room} onChange={set("room")} className={inputClass} required disabled={!chosen}>
                <option value="">{chosen ? "Choose a room" : "Choose a venue first"}</option>
                {rooms.map((r) => (
                  <option key={r} value={r}>{r}</option>
                ))}
              </select>
              {chosen && chosen.rooms.length === 0 && (
                <p className="mt-1 text-xs text-amber-700">This venue has no rooms yet. Add some on the Venues page.</p>
              )}
            </div>
          </>
        )}
        <div>
          <label htmlFor="ex-start-date" className={labelClass}>Exam date (UK time)</label>
          <input id="ex-start-date" type="date" value={f.startDate} onChange={set("startDate")} className={inputClass} required />
        </div>
        <div>
          <label htmlFor="ex-start-time" className={labelClass}>Start time (UK time)</label>
          <input id="ex-start-time" type="time" value={f.startTime} onChange={set("startTime")} className={inputClass} required />
        </div>
        <div>
          <label htmlFor="ex-duration" className={labelClass}>Duration (minutes)</label>
          <input id="ex-duration" type="number" min={15} max={600} step={1} value={f.duration} onChange={set("duration")} className={inputClass} required />
        </div>
        <div>
          <label htmlFor="ex-deadline-date" className={labelClass}>Booking deadline date</label>
          <input id="ex-deadline-date" type="date" value={f.deadlineDate} onChange={set("deadlineDate")} className={inputClass} required />
        </div>
        <div>
          <label htmlFor="ex-deadline-time" className={labelClass}>Booking deadline time</label>
          <input id="ex-deadline-time" type="time" value={f.deadlineTime} onChange={set("deadlineTime")} className={inputClass} required />
        </div>
        <div>
          <label htmlFor="ex-seats" className={labelClass}>Seat limit</label>
          <input id="ex-seats" type="number" min={1} max={1000} step={1} value={f.seats} onChange={set("seats")} className={inputClass} required />
        </div>
        {withPrice && (
          <div>
            <label htmlFor="ex-price" className={labelClass}>Price (£)</label>
            <input
              id="ex-price"
              inputMode="decimal"
              placeholder="15.00"
              value={f.price}
              onChange={set("price")}
              className={inputClass}
              required
            />
            <p className="mt-1 text-xs text-slate-500">
              {unconfirmed
                ? "A teacher created this draft. Saving confirms this price, which you need before publishing."
                : "Use 0 for a free exam. The price cannot change once the exam has bookings."}
            </p>
          </div>
        )}
      </div>
      <div className="flex justify-end gap-2">
        <button type="button" onClick={onCancel} disabled={busy} className="rounded border border-slate-300 px-4 py-2 text-sm hover:bg-slate-50 disabled:opacity-60">
          Close
        </button>
        <button type="submit" disabled={busy} className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60">
          {busy ? "Saving..." : exam ? "Save exam" : "Create exam"}
        </button>
      </div>
    </form>
  );
}
