"use server";

import { revalidatePath } from "next/cache";
import { collectionMessageFor, type CollectionContext } from "@stem/shared";
import type { ManifestData, ManifestRow } from "@/lib/manifest-pdf";
import { formatLondon } from "@/lib/money";
import { requireStaff } from "@/lib/staff-gate";
import { createClient } from "@/lib/supabase/server";
import { isUuid } from "@/lib/uuid";

// Collection of scripts after the exam: sheets per candidate, the manifest, and the custody trail. Whoever keeps the
// register may do all of it; the database checks that the teacher teaches the exam's subject.
const STAFF = ["admin", "owner", "teacher"] as const;

export type SimpleOutcome = { ok: true } | { ok: false; message: string };
export type ManifestOutcome = { ok: true; manifest: ManifestData } | { ok: false; message: string };
export type CustodyInput = { step: string; from: string; to: string; location: string; note: string };

const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

function failure(data: unknown, error: unknown, context: CollectionContext): { ok: false; message: string } {
  const code = !error && isObject(data) && typeof data.code === "string" ? data.code : undefined;
  return { ok: false, message: collectionMessageFor(code, context) };
}

function refresh() {
  revalidatePath("/admin/attendance/[examId]", "page");
  revalidatePath("/teacher/attendance/[examId]", "page");
}

/** Records the extra sheets counted for one candidate (the printed copy is always one booklet). */
export async function collectionRecordAction(bookingId: string, extraSheets: number): Promise<SimpleOutcome> {
  await requireStaff(STAFF);
  if (!isUuid(bookingId) || !Number.isInteger(extraSheets)) return { ok: false, message: collectionMessageFor("invalid_input", "record") };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("collection_record", { p_booking: bookingId, p_extra_sheets: extraSheets });
  refresh();
  if (error || !isObject(data) || data.ok !== true) return failure(data, error, "record");
  return { ok: true };
}

type CentreQuery = { id: string; room: string; venue: { name: string } | { name: string }[] | null };

/** Makes a new manifest number and returns what the printed manifest shows. The PDF itself is made in the browser. */
export async function manifestCreateAction(examId: string, centreId: string): Promise<ManifestOutcome> {
  await requireStaff(STAFF);
  if (!isUuid(examId) || !isUuid(centreId)) return { ok: false, message: collectionMessageFor("not_found", "manifest") };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("collection_manifest_create", { p_exam: examId, p_centre: centreId });
  if (error || !isObject(data) || data.ok !== true || typeof data.number !== "string" || !Array.isArray(data.rows)) {
    return failure(data, error, "manifest");
  }
  refresh();
  const { data: exam } = await supabase
    .from("exams")
    .select("title, exam_code, starts_at, centres:exam_centres(id, room, venue:venues(name))")
    .eq("id", examId)
    .maybeSingle();
  const centre = ((exam?.centres ?? []) as unknown as CentreQuery[]).find((c) => c.id === centreId);
  const venue = Array.isArray(centre?.venue) ? centre.venue[0] : centre?.venue;
  const rows: ManifestRow[] = [];
  for (const r of data.rows) {
    if (!isObject(r)) continue;
    rows.push({
      index_number: typeof r.index_number === "string" ? r.index_number : null,
      name: typeof r.name === "string" ? r.name : "",
      attendance: typeof r.attendance === "string" ? r.attendance : "not_marked",
      extra_sheets: typeof r.extra_sheets === "number" ? r.extra_sheets : null,
    });
  }
  return {
    ok: true,
    manifest: {
      number: data.number,
      examTitle: exam?.title ?? "",
      examCode: exam?.exam_code ?? "",
      centre: centre ? `${venue?.name ?? ""}, ${centre.room}` : "",
      date: exam?.starts_at ? formatLondon(exam.starts_at) : "",
      madeAt: formatLondon(new Date().toISOString()),
      rows,
    },
  };
}

/** Records that the scripts were collected, handed over, scanned or archived. Empty from/to mean nobody is named. */
export async function custodyRecordAction(examId: string, centreId: string, input: CustodyInput): Promise<SimpleOutcome> {
  await requireStaff(STAFF);
  const person = (v: unknown) => (typeof v === "string" && v !== "" ? v : null);
  const from = person(input?.from);
  const to = person(input?.to);
  if (!isUuid(examId) || !isUuid(centreId) || (from !== null && !isUuid(from)) || (to !== null && !isUuid(to))) {
    return { ok: false, message: collectionMessageFor("invalid_input", "custody") };
  }
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("custody_record", {
    p_exam: examId,
    p_centre: centreId,
    p_step: String(input.step ?? ""),
    p_from: from as string, // null means nobody is named; the generated type does not show that
    p_to: to as string,
    p_location: String(input.location ?? ""),
    p_note: String(input.note ?? ""),
  });
  refresh();
  if (error || !isObject(data) || data.ok !== true) return failure(data, error, "custody");
  return { ok: true };
}
