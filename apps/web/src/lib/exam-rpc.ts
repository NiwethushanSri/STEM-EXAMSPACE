import "server-only";
import { examMessageFor, type ExamContext } from "@stem/shared";
import { createClient } from "@/lib/supabase/server";
import type { ExamValues } from "@/lib/exam-form";
import { formatPence } from "@/lib/money";

export type RpcOutcome = { ok: true; id: string } | { ok: false; message: string };

type Client = Awaited<ReturnType<typeof createClient>>;

/**
 * Reads the {ok, code, message?} answer of an exam or venue function. A transport error, an odd reply
 * or an unknown code gets the generic message. The functions' own short message (for example
 * "Confirm the price first") is shown when they send one.
 */
export function readRpc(data: unknown, error: unknown, context: ExamContext): RpcOutcome {
  if (error || !data || typeof data !== "object" || Array.isArray(data)) {
    return { ok: false, message: examMessageFor(undefined, context) };
  }
  const res = data as { ok?: unknown; id?: unknown; code?: unknown; message?: unknown };
  if (res.ok === true && typeof res.id === "string") return { ok: true, id: res.id };
  if (typeof res.message === "string" && res.message.length > 0 && res.message.length <= 120) {
    return { ok: false, message: `${res.message}.` };
  }
  return { ok: false, message: examMessageFor(typeof res.code === "string" ? res.code : undefined, context) };
}

/** Calls save_exam with the parsed form. `pricePence` is ignored by the database for teachers. */
export async function callSaveExam(supabase: Client, v: ExamValues, pricePence: number): Promise<{ data: unknown; error: unknown }> {
  return supabase.rpc("save_exam", {
    p_id: v.id as unknown as string,
    p_subject_id: v.subjectId,
    p_title: v.title,
    p_paper: v.paper,
    p_format: v.format,
    p_centres: v.centres.map((c) => ({ ...(c.id ? { id: c.id } : {}), venue_id: c.venueId, room: c.room, seat_limit: c.seatLimit })),
    p_starts_at: v.startsAt,
    p_duration_minutes: v.durationMinutes,
    p_price_pence: pricePence,
    p_booking_deadline: v.bookingDeadline,
  });
}

/**
 * save_exam answers "conflict" for several different reasons. Looks at the exam to tell the admin which
 * one applies (cancelled exam, seat limit below seats taken, price locked by bookings), else the generic text.
 */
export async function explainSaveConflict(supabase: Client, v: ExamValues): Promise<string> {
  if (!v.id) return examMessageFor("conflict", "save_exam");
  const { data: exam } = await supabase.from("exams").select("status, price_pence, subject_id, starts_at, booking_deadline").eq("id", v.id).maybeSingle();
  if (!exam) return examMessageFor("not_found", "save_exam");
  if (exam.status === "cancelled" || exam.status === "completed") {
    return `This exam is ${exam.status} and can no longer be edited.`;
  }
  if (exam.status === "published") {
    const same = (a: string, b: string) => new Date(a).getTime() === new Date(b).getTime();
    const startsChanged = !same(v.startsAt, exam.starts_at);
    const deadlineChanged = !same(v.bookingDeadline, exam.booking_deadline);
    if (new Date(exam.starts_at).getTime() <= Date.now() && (startsChanged || deadlineChanged)) {
      return "This exam has started — its date and deadline can't change.";
    }
    if (deadlineChanged && new Date(v.bookingDeadline).getTime() <= Date.now()) {
      return "The booking deadline can't be moved into the past.";
    }
  }
  const { count: taken } = await supabase
    .from("bookings")
    .select("id", { count: "exact", head: true })
    .eq("exam_id", v.id)
    .in("status", ["awaiting_payment", "paid", "cancel_requested"]);
  // Seats taken per centre, to tell which centre was shrunk or removed too far.
  const { data: current } = await supabase
    .from("exam_centres")
    .select("id, room, seat_limit, venue:venues(name)")
    .eq("exam_id", v.id)
    .is("removed_at", null);
  const { data: held } = await supabase
    .from("bookings")
    .select("centre_id")
    .eq("exam_id", v.id)
    .not("centre_id", "is", null)
    .in("status", ["awaiting_payment", "paid", "cancel_requested"]);
  const takenAt = new Map<string, number>();
  for (const b of held ?? []) if (b.centre_id) takenAt.set(b.centre_id, (takenAt.get(b.centre_id) ?? 0) + 1);
  type CurrentCentre = { id: string; room: string; seat_limit: number; venue: { name: string } | { name: string }[] | null };
  for (const c of (current ?? []) as unknown as CurrentCentre[]) {
    const name = `${(Array.isArray(c.venue) ? c.venue[0]?.name : c.venue?.name) ?? "Venue"} · ${c.room}`;
    const n = takenAt.get(c.id) ?? 0;
    if (n === 0) continue;
    const kept = v.centres.find((k) => k.id === c.id);
    if (!kept) {
      return `${name} cannot be removed: it has ${n} booking${n === 1 ? "" : "s"}. Cancel or move them first.`;
    }
    if (kept.seatLimit < n) {
      return `The seat limit at ${name} cannot be lower than the ${n} seat${n === 1 ? "" : "s"} already booked there. Cancel some bookings first, or choose ${n} or more.`;
    }
  }
  if (v.pricePence !== null && v.pricePence !== exam.price_pence) {
    return `The price cannot be changed (it is currently ${formatPence(exam.price_pence)}) because this exam already has bookings.`;
  }
  if (v.subjectId !== exam.subject_id && taken) {
    return "The subject cannot be changed on a published exam that already has bookings.";
  }
  return examMessageFor("conflict", "save_exam");
}
