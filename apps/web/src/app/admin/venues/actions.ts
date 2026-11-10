"use server";

import { revalidatePath } from "next/cache";
import { readRpc } from "@/lib/exam-rpc";
import { isUuid, parseRooms } from "@/lib/exam-form";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";

export type VenueActionResult = { ok: true; message: string } | { ok: false; message: string };

/** Create or edit a venue (owner and admin). `rooms` is the textarea text, one room per line. */
export async function saveVenueAction(input: { id: string; name: string; rooms: string; active: boolean }): Promise<VenueActionResult> {
  await requireStaff(["admin", "owner"]);
  const id = typeof input?.id === "string" && input.id ? input.id : null;
  if (id && !isUuid(id)) return { ok: false, message: "This venue could not be found. Refresh the page." };
  const name = String(input?.name ?? "").trim();
  if (!name) return { ok: false, message: "Enter a venue name." };
  const rooms = parseRooms(String(input?.rooms ?? ""));
  if (new Set(rooms.map((r) => r.toLowerCase())).size !== rooms.length) {
    return { ok: false, message: "Each room can only be listed once." };
  }

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("save_venue", {
    p_id: id as unknown as string,
    p_name: name,
    p_rooms: rooms,
    p_active: input?.active === true,
  });
  const out = readRpc(data, error, "save_venue");
  revalidatePath("/admin/venues");
  revalidatePath("/admin/exams");
  revalidatePath("/teacher/exams");
  return out.ok ? { ok: true, message: id ? "Venue saved." : "Venue added." } : out;
}
