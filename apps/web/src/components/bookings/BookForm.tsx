"use client";

import { useActionState, useState } from "react";
import { bookExam, type BookState } from "@/app/exams/[id]/book/actions";
import { centresFullNote } from "@/lib/booking-choice";
import { SITTING_MODE_LABEL } from "@/lib/exam-form";
import type { PublicCentre } from "@/lib/home-exams";

export type Child = { id: string; name: string };

const seatsText = (n: number) => (n <= 0 ? "full" : `${n} seat${n === 1 ? "" : "s"} left`);

export function BookForm({
  examId,
  kids,
  format,
  centres,
}: {
  examId: string;
  kids: Child[] | null;
  format: "in_person" | "online" | "both";
  centres: PublicCentre[];
}) {
  const [state, action, pending] = useActionState<BookState, FormData>(bookExam, { error: null });
  const [sitting, setSitting] = useState<"centre" | "home" | null>(format === "in_person" ? "centre" : format === "online" ? "home" : null);
  // Every centre full on an exam that can also be sat at home: the centre is not offered, and the page says why.
  const fullNote = centresFullNote(format, centres);
  // Asked only when the exam is sat at a centre and has several to choose from.
  const askCentre = sitting === "centre" && centres.length > 1 && !fullNote;
  return (
    <form action={action} className="mt-6 space-y-4">
      <input type="hidden" name="exam" value={examId} />
      {kids && (
        <div>
          <label htmlFor="student" className="block text-sm font-medium text-slate-700">Book for</label>
          <select id="student" name="student" required className="mt-1 w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm">
            {kids.map((c) => (
              <option key={c.id} value={c.id}>{c.name}</option>
            ))}
          </select>
        </div>
      )}
      {format === "both" && (
        <fieldset>
          <legend className="block text-sm font-medium text-slate-700">Where will they sit it?</legend>
          <div className="mt-1 space-y-2">
            {(["centre", "home"] as const).map((m) => {
              const off = m === "centre" && !!fullNote;
              return (
                <label
                  key={m}
                  className={`flex items-center gap-2 rounded-lg border border-slate-300 px-3 py-2 text-sm ${off ? "bg-slate-100 text-slate-500" : "bg-white"}`}
                >
                  <input
                    type="radio"
                    name="sitting"
                    value={m}
                    required
                    disabled={off}
                    aria-describedby={off ? "centres-full" : undefined}
                    checked={sitting === m}
                    onChange={() => setSitting(m)}
                  />
                  {SITTING_MODE_LABEL[m]}
                  {off && <span className="ml-auto text-slate-500">full</span>}
                </label>
              );
            })}
          </div>
          {fullNote && (
            <p id="centres-full" data-testid="centres-full" className="mt-2 text-sm text-amber-900">{fullNote}</p>
          )}
        </fieldset>
      )}
      {askCentre && (
        <fieldset>
          <legend className="block text-sm font-medium text-slate-700">Which centre?</legend>
          <div className="mt-1 space-y-2">
            {centres.map((c) => (
              <label
                key={c.id}
                className={`flex items-center gap-2 rounded-lg border border-slate-300 px-3 py-2 text-sm ${c.seats_left <= 0 ? "bg-slate-100 text-slate-500" : "bg-white"}`}
              >
                <input type="radio" name="centre" value={c.id} required disabled={c.seats_left <= 0} />
                <span className="font-medium">{c.venue}</span>
                <span className="ml-auto text-slate-500">{seatsText(c.seats_left)}</span>
              </label>
            ))}
          </div>
        </fieldset>
      )}
      {state.error && (
        <p role="alert" className="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-700">{state.error}</p>
      )}
      <button
        type="submit"
        disabled={pending}
        className="rounded-lg bg-blue-600 px-5 py-2.5 font-semibold text-white hover:bg-blue-700 disabled:opacity-60"
      >
        {pending ? "Booking..." : "Confirm booking"}
      </button>
    </form>
  );
}
