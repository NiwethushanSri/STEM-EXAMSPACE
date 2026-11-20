import "server-only";
import { createClient } from "@/lib/supabase/server";

export type CollectionRow = {
  bookingId: string;
  indexNumber: string;
  name: string;
  attendance: "present" | "late";
  /** Extra sheets counted; null until someone counts. */
  extraSheets: number | null;
};

export type CustodyStep = "collected" | "handed_over" | "scanned" | "archived";
export type CustodyEvent = {
  id: string;
  step: CustodyStep;
  at: string;
  location: string;
  note: string | null;
  manifest: string | null;
  fromName: string | null;
  toName: string | null;
  byName: string | null;
};
export type StaffOption = { id: string; name: string; role: string };

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/** Candidates of a centre who sat the exam (present or late), with the extra sheets counted so far. Empty when the caller may not see it. */
export async function loadCollection(examId: string, centreId: string): Promise<CollectionRow[]> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("collection_list", { p_exam: examId, p_centre: centreId });
  if (error || !isObject(data) || data.ok !== true || !Array.isArray(data.rows)) return [];
  const out: CollectionRow[] = [];
  for (const r of data.rows) {
    if (!isObject(r) || typeof r.booking_id !== "string" || (r.attendance !== "present" && r.attendance !== "late")) continue;
    out.push({
      bookingId: r.booking_id,
      indexNumber: str(r.index_number) ?? "-",
      name: str(r.name) ?? "Student",
      attendance: r.attendance,
      extraSheets: typeof r.extra_sheets === "number" ? r.extra_sheets : null,
    });
  }
  return out;
}

const STEPS: readonly string[] = ["collected", "handed_over", "scanned", "archived"];

/** The custody trail of a centre, oldest first, and the staff a handover can name. */
export async function loadCustody(examId: string, centreId: string): Promise<{ events: CustodyEvent[]; staff: StaffOption[] }> {
  const supabase = await createClient();
  const [list, staff] = await Promise.all([
    supabase.rpc("custody_list", { p_exam: examId, p_centre: centreId }),
    supabase.rpc("custody_staff", { p_exam: examId, p_centre: centreId }),
  ]);
  const events: CustodyEvent[] = [];
  if (!list.error && isObject(list.data) && list.data.ok === true && Array.isArray(list.data.events)) {
    for (const e of list.data.events) {
      if (!isObject(e) || typeof e.id !== "string" || typeof e.step !== "string" || !STEPS.includes(e.step) || typeof e.at !== "string") continue;
      events.push({
        id: e.id,
        step: e.step as CustodyStep,
        at: e.at,
        location: str(e.location) ?? "",
        note: str(e.note),
        manifest: str(e.manifest),
        fromName: str(e.from_name),
        toName: str(e.to_name),
        byName: str(e.by_name),
      });
    }
  }
  const people: StaffOption[] = [];
  if (!staff.error && isObject(staff.data) && staff.data.ok === true && Array.isArray(staff.data.staff)) {
    for (const s of staff.data.staff) {
      if (isObject(s) && typeof s.id === "string" && typeof s.role === "string") people.push({ id: s.id, name: str(s.name) ?? "Staff member", role: s.role });
    }
  }
  return { events, staff: people };
}
