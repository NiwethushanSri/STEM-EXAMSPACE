import "server-only";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { requireStaff } from "@/lib/staff-gate";
import { isUuid } from "@/lib/uuid";
import { centresOf } from "@/lib/exams-staff";
import { parseScanStatus, type ScanBatchStatus } from "@/lib/scan-batch";

type Embedded<T> = T | T[] | null;
const one = <T,>(v: Embedded<T>): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));
const fullName = (p: { first_name: string; last_name: string } | null) => (p ? `${p.first_name} ${p.last_name}`.trim() : "Removed account");

export type PaperVersion = {
  id: string;
  kind: "paper" | "insert";
  title: string;
  version: number;
  pageCount: number;
  byteSize: number;
  uploadedBy: string;
  uploadedAt: string;
  replaceReason: string | null;
  current: boolean;
  /** When an admin last saved the page roles (null: not reviewed yet; always null for an insert). */
  pagesReviewedAt: string | null;
};

export type PageRole = "answer" | "cover" | "blank" | "information";
export type PaperLayout = {
  pages: { page: number; role: PageRole }[];
  areas: { id: string; page: number; x: number; y: number; w: number; h: number }[];
};

export type PackCandidate = { bookingId: string; indexNumber: string; name: string };
export type PackCentre = { id: string; venue: string; room: string; candidates: PackCandidate[] };
export type DownloadEntry = { id: number; at: string; by: string; indexNumber: string; kind: string; version: number };

export type ExamAdminView = {
  exam: {
    id: string;
    title: string;
    paper: string;
    subject: string;
    status: "draft" | "published" | "cancelled" | "completed";
    startsAt: string;
    examCode: string;
    releaseMinutesBefore: number;
    sparePages: number;
    held: boolean;
    releasedEarlyAt: string | null;
  };
  releaseAt: string;
  papers: PaperVersion[];
  /** Page roles and hidden areas of the current paper (null when there is none). */
  layout: PaperLayout | null;
  /** Any copy of any version exists: the exam code is locked. */
  hasCopies: boolean;
  /** Any copy of the current paper exists: replacing it needs a reason. */
  currentHasCopies: boolean;
  centres: PackCentre[];
  downloads: DownloadEntry[];
  downloadsCapped: boolean;
};

const LOG_CAP = 200;
const PAGE = 1000;

type PaperQueryRow = {
  id: string;
  kind: "paper" | "insert";
  title: string;
  version: number;
  page_count: number;
  byte_size: number;
  uploaded_at: string;
  replace_reason: string | null;
  superseded_at: string | null;
  pages_reviewed_at: string | null;
  uploader: Embedded<{ first_name: string; last_name: string }>;
};

type BookingQueryRow = {
  id: string;
  centre_id: string | null;
  student: Embedded<{ first_name: string; last_name: string; student_details: Embedded<{ index_number: string | null }> }>;
};

type DownloadQueryRow = {
  id: number;
  at: string;
  kind: string;
  who: Embedded<{ first_name: string; last_name: string }>;
  copy: Embedded<{
    paper: Embedded<{ version: number }>;
    booking: Embedded<{ student: Embedded<{ student_details: Embedded<{ index_number: string | null }> }> }>;
  }>;
};

/** Everything the admin exam page shows. Admin and owner only (RLS also limits every table read here to them). */
export async function loadExamAdmin(examId: string): Promise<ExamAdminView> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) notFound();
  const supabase = await createClient();

  const { data: exam, error: examErr } = await supabase
    .from("exams")
    .select(
      "id, title, paper, status, starts_at, exam_code, release_minutes_before, spare_pages, release_held, released_early_at, subject:subjects(name), centres:exam_centres(id, venue_id, room, seat_limit, removed_at, created_at, venue:venues(name))",
    )
    .eq("id", examId)
    .maybeSingle();
  if (examErr) throw new Error("exam could not be loaded");
  if (!exam) notFound();

  const [papersRes, releaseRes, bookings, downloadsRes] = await Promise.all([
    supabase
      .from("exam_papers")
      .select("id, kind, title, version, page_count, byte_size, uploaded_at, replace_reason, superseded_at, pages_reviewed_at, uploader:profiles!exam_papers_uploaded_by_fkey(first_name, last_name)")
      .eq("exam_id", examId)
      .order("kind", { ascending: true })
      .order("version", { ascending: false }),
    supabase.rpc("paper_release_at", { p_exam: examId }),
    loadCandidates(examId),
    supabase
      .from("paper_downloads")
      .select(
        "id, at, kind, who:profiles!paper_downloads_downloaded_by_fkey(first_name, last_name), copy:paper_copies!inner(paper:exam_papers!inner(exam_id, version), booking:bookings(student:profiles!bookings_student_id_fkey(student_details!profile_id(index_number))))",
      )
      .eq("copy.paper.exam_id", examId)
      .order("at", { ascending: false })
      .order("id", { ascending: false })
      .limit(LOG_CAP + 1),
  ]);
  if (papersRes.error || releaseRes.error || downloadsRes.error) throw new Error("exam paper data could not be loaded");

  const papers = ((papersRes.data ?? []) as unknown as PaperQueryRow[]).map<PaperVersion>((p) => ({
    id: p.id,
    kind: p.kind,
    title: p.title,
    version: p.version,
    pageCount: p.page_count,
    byteSize: p.byte_size,
    uploadedBy: fullName(one(p.uploader)),
    uploadedAt: p.uploaded_at,
    replaceReason: p.replace_reason,
    current: p.superseded_at === null,
    pagesReviewedAt: p.pages_reviewed_at,
  }));

  let layout: PaperLayout | null = null;
  const currentPaper = papers.find((p) => p.kind === "paper" && p.current);
  if (currentPaper) {
    const { data: lay, error: layErr } = await supabase.rpc("paper_page_layout", { p_paper: currentPaper.id });
    const l = lay as { ok?: boolean; pages?: PaperLayout["pages"]; areas?: PaperLayout["areas"] } | null;
    if (layErr || !l || l.ok !== true) throw new Error("page roles could not be loaded");
    layout = { pages: l.pages ?? [], areas: l.areas ?? [] };
  }

  const paperIds = papers.map((p) => p.id);
  let hasCopies = false;
  let currentHasCopies = false;
  if (paperIds.length > 0) {
    const { data: copies, error } = await supabase.from("paper_copies").select("id").in("paper_id", paperIds).limit(1);
    if (error) throw new Error("copies could not be checked");
    hasCopies = (copies ?? []).length > 0;
    const current = papers.find((p) => p.kind === "paper" && p.current);
    if (current) {
      const { data: cur, error: e2 } = await supabase.from("paper_copies").select("id").eq("paper_id", current.id).limit(1);
      if (e2) throw new Error("copies could not be checked");
      currentHasCopies = (cur ?? []).length > 0;
    }
  }

  const byCentre = new Map<string, PackCandidate[]>();
  for (const b of bookings) {
    if (!b.centre_id) continue;
    const st = one(b.student);
    const list = byCentre.get(b.centre_id) ?? [];
    list.push({
      bookingId: b.id,
      indexNumber: (st ? one(st.student_details)?.index_number : null) ?? "No index number",
      name: fullName(st),
    });
    byCentre.set(b.centre_id, list);
  }
  const centres = centresOf(exam as unknown as Parameters<typeof centresOf>[0]).map<PackCentre>((c) => ({
    id: c.id,
    venue: one(c.venue)?.name ?? "",
    room: c.room,
    candidates: (byCentre.get(c.id) ?? []).sort((a, b) => a.indexNumber.localeCompare(b.indexNumber) || a.bookingId.localeCompare(b.bookingId)),
  }));

  const rawLog = (downloadsRes.data ?? []) as unknown as DownloadQueryRow[];
  const downloads = rawLog.slice(0, LOG_CAP).map<DownloadEntry>((d) => {
    const copy = one(d.copy);
    const student = one(one(copy?.booking ?? null)?.student ?? null);
    return {
      id: d.id,
      at: d.at,
      by: fullName(one(d.who)),
      indexNumber: (student ? one(student.student_details)?.index_number : null) ?? "",
      kind: d.kind,
      version: one(copy?.paper ?? null)?.version ?? 0,
    };
  });

  const e = exam as unknown as {
    id: string;
    title: string;
    paper: string;
    status: ExamAdminView["exam"]["status"];
    starts_at: string;
    exam_code: string;
    release_minutes_before: number;
    spare_pages: number;
    release_held: boolean;
    released_early_at: string | null;
    subject: Embedded<{ name: string }>;
  };
  return {
    exam: {
      id: e.id,
      title: e.title,
      paper: e.paper,
      subject: one(e.subject)?.name ?? "",
      status: e.status,
      startsAt: e.starts_at,
      examCode: e.exam_code,
      releaseMinutesBefore: e.release_minutes_before,
      sparePages: e.spare_pages,
      held: e.release_held,
      releasedEarlyAt: e.released_early_at,
    },
    releaseAt: (releaseRes.data as string | null) ?? e.starts_at,
    papers,
    layout,
    hasCopies,
    currentHasCopies,
    centres,
    downloads,
    downloadsCapped: rawLog.length > LOG_CAP,
  };
}

const SCAN_BATCH_CAP = 200;

/** The exam's scan batches with their status, oldest first. Staff admins only (scan_batches is readable by them
 * alone, and scan_batch_status checks again). */
export async function loadScanBatches(examId: string): Promise<ScanBatchStatus[]> {
  await requireStaff(["admin", "owner"]);
  if (!isUuid(examId)) return [];
  const supabase = await createClient();
  const { data, error } = await supabase
    .from("scan_batches")
    .select("id")
    .eq("exam_id", examId)
    .order("created_at", { ascending: true })
    .order("id", { ascending: true })
    .limit(SCAN_BATCH_CAP);
  if (error) throw new Error("scan batches could not be loaded");
  const answers = await Promise.all((data ?? []).map((b) => supabase.rpc("scan_batch_status", { p_batch: b.id })));
  return answers.map((r) => (r.error ? null : parseScanStatus(r.data))).filter((s): s is ScanBatchStatus => s !== null);
}

/** The paid and cancel-requested centre bookings of the exam, a page at a time. */
async function loadCandidates(examId: string): Promise<BookingQueryRow[]> {
  const supabase = await createClient();
  const out: BookingQueryRow[] = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await supabase
      .from("bookings")
      .select("id, centre_id, student:profiles!bookings_student_id_fkey(first_name, last_name, student_details!profile_id(index_number))")
      .eq("exam_id", examId)
      .eq("sitting", "centre")
      .in("status", ["paid", "cancel_requested"])
      .order("id", { ascending: true })
      .range(from, from + PAGE - 1);
    if (error) throw new Error("candidates could not be loaded");
    const rows = (data ?? []) as unknown as BookingQueryRow[];
    out.push(...rows);
    if (rows.length < PAGE) break;
  }
  return out;
}
