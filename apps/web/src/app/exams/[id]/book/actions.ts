"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { bookingMessageFor, messageFor } from "@stem/shared";
import { createClient, getSessionProfile } from "@/lib/supabase/server";

export type BookState = { error: string | null };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Book a seat. Runs as the signed-in family member (never the service role); create_booking re-checks everything. */
export async function bookExam(_prev: BookState, form: FormData): Promise<BookState> {
  const me = await getSessionProfile();
  if (!me) return { error: messageFor("unauthenticated") };
  if ((me.role !== "student" && me.role !== "parent") || me.status !== "active") return { error: messageFor("forbidden") };

  const examId = String(form.get("exam") ?? "");
  // A student always books for themselves, whatever the form says.
  const studentId = me.role === "student" ? me.id : String(form.get("student") ?? "");
  if (!UUID.test(examId) || !UUID.test(studentId)) return { error: bookingMessageFor("invalid_input") };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_booking", { p_exam: examId, p_student: studentId });
  if (error || !data || typeof data !== "object" || Array.isArray(data)) return { error: messageFor("internal") };
  const res = data as { ok?: boolean; code?: string };
  if (!res.ok) return { error: bookingMessageFor(res.code) };

  revalidatePath("/exams");
  revalidatePath("/account/bookings");
  redirect("/account/bookings?booked=1");
}
