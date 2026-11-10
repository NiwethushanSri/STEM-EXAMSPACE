"use server";

import { revalidatePath } from "next/cache";
import { bookingMessageFor, messageFor } from "@stem/shared";
import { createClient, getSessionProfile } from "@/lib/supabase/server";

export type CancelState = { error: string | null; done: boolean };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Cancel an unpaid booking, or ask for a cancellation of a paid one. The database decides which applies. */
export async function cancelBooking(_prev: CancelState, form: FormData): Promise<CancelState> {
  const me = await getSessionProfile();
  if (!me) return { error: messageFor("unauthenticated"), done: false };
  if ((me.role !== "student" && me.role !== "parent") || me.status !== "active") {
    return { error: messageFor("forbidden"), done: false };
  }
  const booking = String(form.get("booking") ?? "");
  if (!UUID.test(booking)) return { error: bookingMessageFor("invalid_input"), done: false };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("request_cancellation", { p_booking: booking });
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { error: messageFor("internal"), done: false };
  const res = data as { ok?: boolean; code?: string };
  if (!res.ok) {
    // The row may have changed under the user (paid, expired, exam started): show the real state next.
    revalidatePath("/account/bookings");
    return { error: bookingMessageFor(res.code), done: false };
  }
  revalidatePath("/account/bookings");
  revalidatePath("/exams");
  return { error: null, done: true };
}
