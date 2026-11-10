"use client";

import { useActionState } from "react";
import { bookExam, type BookState } from "@/app/exams/[id]/book/actions";

export type Child = { id: string; name: string };

export function BookForm({ examId, kids }: { examId: string; kids: Child[] | null }) {
  const [state, action, pending] = useActionState<BookState, FormData>(bookExam, { error: null });
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
