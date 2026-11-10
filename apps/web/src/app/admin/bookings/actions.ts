"use server";

import { revalidatePath } from "next/cache";
import { adminBookingMessageFor, messageFor, type AdminBookingContext } from "@stem/shared";
import { searchStudents, type StudentOption } from "@/lib/bookings-admin";
import { poundsToPence } from "@/lib/money";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

/** What the booking actions send back; they never throw for expected failures. */
export type BookingActionResult = { ok: true; message: string } | { ok: false; message: string };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const NOTE_MAX = 500;

function refresh() {
  revalidatePath("/admin/bookings");
  revalidatePath("/admin/finance");
  revalidatePath("/admin/exams");
  revalidatePath("/account/bookings");
}

/** Reads the {ok, code} answer of a booking function. A transport error or an odd reply gets the generic message. */
function read(data: unknown, error: unknown, context: AdminBookingContext): BookingActionResult | { ok: true; id: string; status?: string } {
  if (error || !data || typeof data !== "object" || Array.isArray(data)) {
    return { ok: false, message: adminBookingMessageFor(undefined, context) };
  }
  const res = data as { ok?: unknown; id?: unknown; status?: unknown; code?: unknown };
  if (res.ok === true && typeof res.id === "string") {
    return { ok: true, id: res.id, status: typeof res.status === "string" ? res.status : undefined };
  }
  return { ok: false, message: adminBookingMessageFor(typeof res.code === "string" ? res.code : undefined, context) };
}

/** A note is optional text of up to 500 characters; null means invalid. */
function cleanNote(note: unknown): string | null | undefined {
  if (note === undefined || note === null) return "";
  if (typeof note !== "string") return undefined;
  const n = note.trim();
  return n.length > NOTE_MAX ? undefined : n;
}

const badInput: BookingActionResult = { ok: false, message: messageFor("invalid_input") };

/** Student search for the add-booking form (owner and admin). */
export async function searchStudentsAction(q: string): Promise<{ ok: true; students: StudentOption[] } | { ok: false; message: string }> {
  await requireStaff(["admin", "owner"]);
  if (typeof q !== "string" || q.trim().length < 2) return { ok: true, students: [] };
  try {
    return { ok: true, students: await searchStudents(q) };
  } catch {
    return { ok: false, message: messageFor("internal") };
  }
}

/** Adds an offline booking for a student (owner and admin). Paid ones may be added after the deadline. */
export async function addBookingAction(examId: string, studentId: string, paid: boolean, note: string): Promise<BookingActionResult> {
  await requireStaff(["admin", "owner"]);
  const n = cleanNote(note);
  if (!UUID.test(String(examId)) || !UUID.test(String(studentId)) || typeof paid !== "boolean" || n === undefined) return badInput;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("admin_add_booking", {
    p_exam: examId,
    p_student: studentId,
    p_paid: paid,
    p_note: n as string,
  });
  const out = read(data, error, "add");
  refresh();
  if (!out.ok) return out;
  return { ok: true, message: paid ? "Booking added and marked as paid." : "Booking added. It is awaiting payment." };
}

/** Marks an unpaid booking as paid offline (owner and admin). */
export async function markPaidAction(bookingId: string, note: string): Promise<BookingActionResult> {
  await requireStaff(["admin", "owner"]);
  const n = cleanNote(note);
  if (!UUID.test(String(bookingId)) || n === undefined) return badInput;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("mark_booking_paid", { p_booking: bookingId, p_note: n as string });
  const out = read(data, error, "mark_paid");
  refresh();
  return out.ok ? { ok: true, message: "Booking marked as paid." } : out;
}

/** Cancels an unpaid booking (owner and admin). */
export async function cancelBookingAction(bookingId: string, note: string): Promise<BookingActionResult> {
  await requireStaff(["admin", "owner"]);
  const n = cleanNote(note);
  if (!UUID.test(String(bookingId)) || n === undefined) return badInput;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("cancel_booking_admin", { p_booking: bookingId, p_note: n as string });
  const out = read(data, error, "cancel");
  refresh();
  return out.ok ? { ok: true, message: "Booking cancelled." } : out;
}

/**
 * Approves a cancellation (recording a manual refund of `refund` pounds, 0 allowed; no payment is sent from
 * here) or declines it (the booking goes back to paid). The database re-checks every rule.
 */
export async function decideCancellationAction(bookingId: string, approve: boolean, refund: string, note: string): Promise<BookingActionResult> {
  await requireStaff(["admin", "owner"]);
  const n = cleanNote(note);
  if (!UUID.test(String(bookingId)) || typeof approve !== "boolean" || n === undefined) return badInput;
  let pence = 0;
  if (approve) {
    const p = typeof refund === "string" ? poundsToPence(refund) : null;
    if (p === null) return { ok: false, message: "Enter the refund in pounds, for example 12.50, or 0 for no refund." };
    pence = p;
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("decide_cancellation", {
    p_booking: bookingId,
    p_approve: approve,
    p_refund_pence: pence,
    p_note: n as string,
  });
  const out = read(data, error, approve ? "approve" : "decline");
  refresh();
  if (!out.ok) return out;
  if (!approve) return { ok: true, message: "Cancellation declined. The booking is paid again." };
  return {
    ok: true,
    message: pence > 0 ? "Cancellation approved and the refund recorded. Pay the family back yourself; nothing was sent." : "Cancellation approved with no refund.",
  };
}
