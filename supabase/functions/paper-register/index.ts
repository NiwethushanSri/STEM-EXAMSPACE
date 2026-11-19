// Admin: checks an uploaded PDF and registers it as the exam's paper (or an insert).
// The browser uploads to the private exam-papers bucket first; this function reads the object with the service
// role, refuses anything unreadable, encrypted or over 20 MB, and deletes the object on every refusal so no
// orphan files are left. The database function does the permission, version and audit work as the caller.
import { callerClient, requireCaller, serviceClient } from "../_shared/auth.ts";
import { type ErrorCode, HttpError, handle, jsonResponse } from "../_shared/errors.ts";
import { inspectPaper, PaperError } from "../_shared/paper/stamp.ts";

const BUCKET = "exam-papers";
const MAX_BYTES = 20 * 1024 * 1024;
/** register_exam_paper takes 1 to 500 pages. */
const MAX_PAGES = 500;
const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const bad = (m: string) => new HttpError("invalid_input", 400, m);

const REFUSALS: Record<string, [ErrorCode, number, string]> = {
  forbidden: ["forbidden", 403, "You do not have permission to do this."],
  not_found: ["not_found", 404, "This exam no longer exists. Refresh the page."],
  conflict: [
    "conflict",
    409,
    "A paper cannot be added to a cancelled or completed exam, and a file can only be registered once.",
  ],
  invalid_input: [
    "invalid_input",
    400,
    "Check the title (up to 120 characters). Replacing a paper that candidates already have needs a reason of 3 to 300 characters.",
  ],
};

function refusal(code: unknown): HttpError {
  const r = typeof code === "string" && Object.hasOwn(REFUSALS, code) ? REFUSALS[code] : null;
  return r ? new HttpError(r[0], r[1], r[2]) : new HttpError("internal", 500, "Something went wrong. Please try again.");
}

Deno.serve(handle(async (req) => {
  if (req.method !== "POST") throw bad("Use POST.");
  await requireCaller(req, ["owner", "admin"]);

  let raw: Record<string, unknown>;
  try {
    raw = (await req.json()) as Record<string, unknown>;
  } catch {
    throw bad("Send a JSON body.");
  }
  const examId = typeof raw.examId === "string" ? raw.examId.toLowerCase() : "";
  const kind = raw.kind;
  const storagePath = typeof raw.storagePath === "string" ? raw.storagePath : "";
  const title = typeof raw.title === "string" ? raw.title : null;
  const reason = typeof raw.reason === "string" ? raw.reason : null;
  if (!new RegExp(`^${UUID}$`).test(examId)) throw bad("Choose an exam.");
  if (kind !== "paper" && kind !== "insert") throw bad("Choose paper or insert.");
  // Only objects under this exam's own folder are ever read or deleted.
  if (!new RegExp(`^${examId}/${UUID}\\.pdf$`).test(storagePath)) throw bad("The uploaded file is not in this exam's folder.");

  const svc = serviceClient();
  // A file that is already registered belongs to a paper in use: never touch it.
  const reg = await svc.from("exam_papers").select("id").eq("storage_path", storagePath).maybeSingle();
  if (reg.error) throw refusal(null);
  if (reg.data) throw refusal("conflict");

  // Re-checks first: if a concurrent request registered this very file, it is in use and must stay.
  const discard = async () => {
    const again = await svc.from("exam_papers").select("id").eq("storage_path", storagePath).maybeSingle();
    if (again.error || again.data) return;
    const { error } = await svc.storage.from(BUCKET).remove([storagePath]);
    if (error) console.error("paper-register: could not delete the refused object");
  };

  // Cheap checks before the object is downloaded; the database function checks them again.
  const t = title?.trim() ?? "";
  const r = reason?.trim() ?? "";
  if (t.length > 120 || (r !== "" && (r.length < 3 || r.length > 300))) {
    await discard();
    throw refusal("invalid_input");
  }

  const dl = await svc.storage.from(BUCKET).download(storagePath);
  if (dl.error || !dl.data) throw bad("The uploaded file was not found. Upload it again.");
  if (dl.data.size > MAX_BYTES) {
    await discard();
    throw new HttpError("paper_too_large", 413, "This PDF is larger than 20 MB. Make it smaller and upload it again.");
  }
  const bytes = new Uint8Array(await dl.data.arrayBuffer());

  let pageCount: number;
  try {
    pageCount = (await inspectPaper(bytes)).pageCount;
  } catch (e) {
    await discard();
    if (e instanceof PaperError && e.reason === "encrypted") {
      throw new HttpError(
        "paper_encrypted",
        422,
        "This PDF is password protected. Remove the password and upload it again.",
      );
    }
    throw new HttpError("paper_unreadable", 422, "This file could not be read as a PDF. Check it and upload it again.");
  }
  if (pageCount > MAX_PAGES) {
    await discard();
    throw new HttpError(
      "invalid_input",
      422,
      `This PDF has more than ${MAX_PAGES} pages. Upload a PDF of at most ${MAX_PAGES} pages.`,
    );
  }

  const { data, error } = await callerClient(req).rpc("register_exam_paper", {
    p_exam: examId,
    p_kind: kind,
    p_title: title,
    p_storage_path: storagePath,
    p_page_count: pageCount,
    p_byte_size: bytes.length,
    p_reason: reason,
  });
  if (error) {
    console.error("register_exam_paper failed:", error.code ?? "unknown");
    await discard();
    throw refusal(null);
  }
  const out = data as { ok: boolean; code?: string; id?: string; version?: number; page_count?: number };
  if (!out.ok) {
    await discard();
    throw refusal(out.code);
  }
  return jsonResponse({ paperId: out.id, version: out.version, pageCount: out.page_count });
}));
