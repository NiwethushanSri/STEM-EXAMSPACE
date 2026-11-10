"use client";

import { useActionState, useState } from "react";
import { cancelBooking, type CancelState } from "@/app/account/bookings/actions";

/** "Cancel booking" (unpaid, immediate) or "Request cancellation" (paid), each behind a confirm step. */
export function CancelButton({ bookingId, paid }: { bookingId: string; paid: boolean }) {
  const [state, action, pending] = useActionState<CancelState, FormData>(cancelBooking, { error: null, done: false });
  const [confirming, setConfirming] = useState(false);
  const label = paid ? "Request cancellation" : "Cancel booking";

  if (state.done) return <p role="status" className="text-sm text-slate-600">{paid ? "Cancellation requested." : "Booking cancelled."}</p>;

  return (
    <div className="space-y-2">
      {state.error && <p role="alert" className="rounded bg-red-50 px-2 py-1 text-sm text-red-700">{state.error}</p>}
      {!confirming ? (
        <button type="button" onClick={() => setConfirming(true)} className="rounded-lg border border-red-300 px-3 py-1.5 text-sm font-medium text-red-700 hover:bg-red-50">
          {label}
        </button>
      ) : (
        <form action={action} className="flex flex-wrap items-center gap-2 text-sm">
          <input type="hidden" name="booking" value={bookingId} />
          <span>{paid ? "Ask the institution to cancel this paid booking?" : "Cancel this booking and release the seat?"}</span>
          <button type="submit" disabled={pending} className="rounded-lg bg-red-600 px-3 py-1.5 font-semibold text-white hover:bg-red-700 disabled:opacity-60">
            {pending ? "Working..." : "Yes, confirm"}
          </button>
          <button type="button" disabled={pending} onClick={() => setConfirming(false)} className="rounded-lg border border-slate-300 px-3 py-1.5 hover:bg-slate-100">
            Keep booking
          </button>
        </form>
      )}
    </div>
  );
}
