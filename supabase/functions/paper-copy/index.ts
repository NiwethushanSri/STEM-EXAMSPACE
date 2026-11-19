// Builds one candidate's personalised copy of the exam paper, or hands out an insert unchanged.
// Every permission and release rule is decided by the database as the caller (paper_copy_issue). The master PDF
// is read with the service role and only ever leaves this function stamped for that candidate: no plain paper is
// returned to a non-admin. The download is logged only after the PDF has been made, and if logging is refused
// (a hold can commit between issue and log) the PDF is not delivered.
import { callerClient, requireCaller, serviceClient } from "../_shared/auth.ts";
import {
  corsHeaders,
  type ErrorCode,
  HttpError,
  handle,
  pdfExposeHeaders,
} from "../_shared/errors.ts";
import { buildCopy } from "../_shared/paper/stamp.ts";

const BUCKET = "exam-papers";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KINDS = ["home", "print_pack", "reprint", "admin_preview"] as const;
type Kind = (typeof KINDS)[number];
const bad = (m: string) => new HttpError("invalid_input", 400, m);
const FAILED = "The paper could not be prepared. Please try again.";

const REFUSALS: Record<string, [ErrorCode, number, string]> = {
  forbidden: ["forbidden", 403, "You do not have permission to do this."],
  not_found: ["not_found", 404, "Not found."],
  paper_missing: ["paper_missing", 409, "Your paper is not ready yet. The institution has been told."],
  paper_held: ["paper_held", 409, "The paper is paused by the institution. Please wait."],
  paper_not_released: ["paper_not_released", 409, "Your paper is not ready to download yet."],
  paper_closed: ["paper_closed", 409, "Downloads for this paper have closed."],
  wrong_sitting: [
    "wrong_sitting",
    409,
    "Your booking is for the centre; your paper is handed out in the exam room",
  ],
  rate_limited: ["rate_limited", 429, "Too many downloads. Try again in a while."],
  invalid_input: ["invalid_input", 400, "Please check the details you entered."],
};

function refusal(code: unknown): HttpError {
  const r = typeof code === "string" && Object.hasOwn(REFUSALS, code) ? REFUSALS[code] : null;
  return r ? new HttpError(r[0], r[1], r[2]) : new HttpError("internal", 500, "Something went wrong. Please try again.");
}

/** "Sat 5 June 2027" in London time. */
function formatExamDate(iso: string): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    weekday: "short",
    day: "numeric",
    month: "long",
    year: "numeric",
  }).formatToParts(new Date(iso));
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return `${get("weekday")} ${get("day")} ${get("month")} ${get("year")}`;
}

/** `version`: the paper version a personalised copy was made from (none for an insert). */
function pdfResponse(bytes: Uint8Array, fileName: string, differs: boolean, version?: number): Response {
  return new Response(bytes as unknown as BodyInit, {
    status: 200,
    headers: {
      ...corsHeaders,
      "Access-Control-Expose-Headers": pdfExposeHeaders,
      "Content-Type": "application/pdf",
      "Content-Disposition": `attachment; filename="${fileName}"`,
      "X-Paper-Differs": differs ? "1" : "0",
      ...(version === undefined ? {} : { "X-Paper-Version": String(version) }),
      "Cache-Control": "no-store",
    },
  });
}

/** Keeps a file name to letters, digits, dot, dash and underscore so it is safe in a header. */
function safeName(text: string, fallback: string): string {
  const cleaned = text.normalize("NFKD").replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "");
  return cleaned || fallback;
}

async function readMaster(path: string): Promise<Uint8Array | null> {
  const dl = await serviceClient().storage.from(BUCKET).download(path);
  if (dl.error || !dl.data) return null;
  return new Uint8Array(await dl.data.arrayBuffer());
}

Deno.serve(handle(async (req) => {
  if (req.method !== "POST") throw bad("Use POST.");
  await requireCaller(req, ["owner", "admin", "student", "parent"]);

  let raw: Record<string, unknown>;
  try {
    raw = (await req.json()) as Record<string, unknown>;
  } catch {
    throw bad("Send a JSON body.");
  }
  const bookingId = typeof raw.bookingId === "string" ? raw.bookingId : "";
  if (!UUID.test(bookingId)) throw bad("Choose a booking.");
  const db = callerClient(req);

  // An insert: the home release rules, then the file exactly as uploaded.
  if (raw.insertId !== undefined) {
    const insertId = typeof raw.insertId === "string" ? raw.insertId : "";
    if (!UUID.test(insertId)) throw bad("Choose an insert.");
    const { data, error } = await db.rpc("paper_insert_issue", { p_booking: bookingId, p_insert: insertId });
    if (error) {
      console.error("paper_insert_issue failed:", error.code ?? "unknown");
      throw refusal(null);
    }
    const issued = data as { ok: boolean; code?: string; storage_path?: string; title?: string };
    if (!issued.ok) throw refusal(issued.code);
    const bytes = await readMaster(issued.storage_path!);
    if (!bytes) throw new HttpError("paper_unreadable", 422, FAILED);
    return pdfResponse(bytes, `${safeName(issued.title ?? "", "insert")}.pdf`, false);
  }

  const kind = raw.kind as Kind;
  if (!KINDS.includes(kind)) throw bad("Choose how the paper is being downloaded.");

  const { data, error } = await db.rpc("paper_copy_issue", { p_booking: bookingId, p_kind: kind });
  if (error) {
    console.error("paper_copy_issue failed:", error.code ?? "unknown");
    throw refusal(null);
  }
  const issued = data as {
    ok: boolean;
    copy_id: string;
    code: string; // the refusal code when not ok, the copy code when ok
    spare_pages: number;
    storage_path: string;
    candidate_name: string;
    index_number: string;
    exam_code: string;
    starts_at: string;
    paper_version: number;
    differs_from_previous: boolean;
  };
  if (!issued.ok) throw refusal(issued.code);

  const master = await readMaster(issued.storage_path);
  if (!master) throw new HttpError("paper_unreadable", 422, FAILED);

  let copy: Uint8Array;
  try {
    copy = await buildCopy(master, {
      candidateName: issued.candidate_name,
      indexNumber: issued.index_number,
      examCode: issued.exam_code,
      examDate: formatExamDate(issued.starts_at),
      code: issued.code,
      sparePages: issued.spare_pages,
    });
  } catch (e) {
    // Name and type only: never the paper, the candidate or the code.
    console.error("paper-copy build failed:", e instanceof Error ? e.name : "unknown");
    throw new HttpError("paper_unreadable", 422, FAILED);
  }

  // Logged only now that the PDF exists. A refusal here (a hold, a rate limit) means the PDF is not delivered.
  const logged = await db.rpc("paper_download_log", { p_copy: issued.copy_id, p_kind: kind });
  if (logged.error) {
    console.error("paper_download_log failed:", logged.error.code ?? "unknown");
    throw refusal(null);
  }
  const log = logged.data as { ok: boolean; code?: string };
  if (!log.ok) throw refusal(log.code);

  const fileName = `${safeName(issued.exam_code, "paper")}-${safeName(issued.index_number, "candidate")}.pdf`;
  return pdfResponse(copy, fileName, issued.differs_from_previous === true, issued.paper_version);
}));
