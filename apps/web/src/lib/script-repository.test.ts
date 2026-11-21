import { describe, expect, it } from "vitest";
import {
  SCRIPT_STATES,
  STATE_LABEL,
  listArgs,
  pageLabel,
  pagesEditable,
  parseFilters,
  parseScriptDetail,
  parseScriptList,
  remaskPending,
  repoDoneMessage,
  repoFailureMessage,
  repoRpc,
  reprocessable,
  stateText,
  turnText,
  voidable,
  type DetailUpload,
} from "./script-repository";

const SCRIPT = "11111111-1111-4111-8111-111111111111";
const PAGE = "22222222-2222-4222-8222-222222222222";
const UPLOAD = "33333333-3333-4333-8333-333333333333";

const item = (over: Record<string, unknown> = {}) => ({
  id: SCRIPT,
  number: "S-ZZ-0001",
  booking_id: "44444444-4444-4444-8444-444444444444",
  source: "centre",
  state: "needs_attention",
  state_reason: null,
  late: false,
  late_decision: null,
  complete: false,
  version: 2,
  pages: 4,
  extra_pages: 0,
  open_exceptions: 1,
  received_at: "2031-08-04T10:00:00Z",
  created_at: "2031-08-04T10:00:00Z",
  exam: { id: "55555555-5555-4555-8555-555555555555", title: "Maths mock", paper: "P1", code: "ZZ" },
  candidate: { name: "Sam One", index_number: "SE-2097-6601" },
  ...over,
});

const page = (over: Record<string, unknown> = {}) => ({
  id: PAGE,
  page_id: PAGE,
  upload_id: UPLOAD,
  source_index: 1,
  copy_page: 2,
  printed_page: 2,
  state: "matched",
  blank: false,
  quality: { sharpness: 200, brightness: 180, cut_off: false, flags: [] },
  rotation: 90,
  turn: 90,
  full_path: "e/u/7/1-full.jpg",
  marking_path: "e/u/9/1-marking.jpg",
  placed_after: null,
  replaced: false,
  paper_version: 2,
  paper_current: true,
  areas: [{ x: 0.1, y: 0.1, w: 0.2, h: 0.05 }],
  extra: false,
  role: "answer",
  ...over,
});

const detail = (over: Record<string, unknown> = {}) => ({
  ok: true,
  script: {
    id: SCRIPT, number: "S-ZZ-0001", source: "home", state: "verified", state_reason: null, version: 1, complete: true, late: false,
    late_decision: null, received_at: "2031-08-04T10:45:00Z", created_at: "2031-08-04T10:45:00Z",
    exam: { id: "55555555-5555-4555-8555-555555555555", title: "Maths mock", paper: "P1", code: "ZZ" },
    booking: { id: "44444444-4444-4444-8444-444444444444", sitting: "home", status: "paid" },
  },
  candidate: { name: "Sam One", index_number: "SE-2097-6601" },
  versions: [{ version: 1, created_at: "2031-08-04T10:45:00Z", reason: "home_submission", by: null, submission_seq: 1, upload_id: null, pages: [1, 2] }],
  pages: [page(), page({ id: "66666666-6666-4666-8666-666666666666", page_id: "66666666-6666-4666-8666-666666666666", copy_page: null, printed_page: null, placed_after: 2, extra: true, role: "extra", marking_path: null })],
  uploads: [{ id: UPLOAD, kind: "home_pdf", state: "processed", source: "home", position: 1, batch_number: null, submission_seq: 1,
              submission_state: "received", created_at: "2031-08-04T10:40:00Z", pages: 5,
              jobs: [{ id: 9, kind: "remask", state: "queued", attempts: 0, last_error: null, created_at: "2031-08-04T11:00:00Z", finished_at: null }] }],
  exceptions: [],
  custody: [{ step: "collected", at: "2031-08-04T11:00:00Z", location: "Exam hall", note: null, manifest: "M-ZZ-01", by_name: "Ada Admin", from_name: null, to_name: null }],
  actions: [{ action: "script_page_rotated", at: "2031-08-04T11:00:00Z", by: "Ada Admin", reason: "Sideways", target_type: "script_page" }],
  ...over,
});

describe("the script list", () => {
  it("parses the list and leaves out malformed items", () => {
    const got = parseScriptList({ ok: true, items: [item(), { id: 3 }, item({ source: "home", late: true, extra_pages: 1 })], more: true });
    expect(got?.more).toBe(true);
    expect(got?.items).toHaveLength(2);
    expect(got?.items[0]).toMatchObject({
      id: SCRIPT, number: "S-ZZ-0001", source: "centre", state: "needs_attention", pages: 4, extraPages: 0, openExceptions: 1,
      exam: { title: "Maths mock" }, candidate: { name: "Sam One", indexNumber: "SE-2097-6601" },
    });
    expect(got?.items[1]).toMatchObject({ source: "home", late: true, extraPages: 1 });
  });
  it("refuses an answer that is not a list", () => {
    expect(parseScriptList({ ok: false, code: "forbidden" })).toBeNull();
    expect(parseScriptList(null)).toBeNull();
  });
  it("reads the filters from the address and makes the call's arguments", () => {
    const f = parseFilters({ exam: "55555555-5555-4555-8555-555555555555", source: "home", state: "needs_attention", late: "yes" });
    expect(f).toEqual({ exam: "55555555-5555-4555-8555-555555555555", source: "home", state: "needs_attention", late: true });
    expect(listArgs(f)).toEqual({ p_exam: f.exam, p_source: "home", p_state: "needs_attention", p_late: true });
    const none = parseFilters({ exam: "not-a-uuid", source: "elsewhere", state: "nope", late: ["no"] });
    expect(none).toEqual({ exam: "", source: null, state: null, late: false });
    expect(listArgs(parseFilters({}))).toEqual({});
  });
  it("labels every state", () => {
    for (const s of SCRIPT_STATES) expect(STATE_LABEL[s]).toBeTruthy();
    expect(stateText("withdrawn", "booking_cancelled")).toBe("Withdrawn (booking cancelled)");
    expect(stateText("void", "voided")).toBe("Void (voided by staff)");
    expect(stateText("void", "late_rejected")).toBe("Void (late script not marked)");
    expect(stateText("verified", null)).toBe("Verified");
  });
});

describe("the script detail", () => {
  it("parses the script, its pages in reading order and the rest", () => {
    const d = parseScriptDetail(detail());
    expect(d?.script).toMatchObject({ number: "S-ZZ-0001", source: "home", state: "verified", exam: { title: "Maths mock" } });
    expect(d?.candidate).toEqual({ name: "Sam One", indexNumber: "SE-2097-6601" });
    expect(d?.pages.map(pageLabel)).toEqual(["Page 2", "Extra page after page 2"]);
    expect(d?.pages[0]).toMatchObject({ pageId: PAGE, turn: 90, markingPath: "e/u/9/1-marking.jpg", areas: [{ x: 0.1, y: 0.1, w: 0.2, h: 0.05 }] });
    expect(d?.versions[0]).toMatchObject({ version: 1, pages: [1, 2], submissionSeq: 1 });
    expect(d?.uploads[0]).toMatchObject({ id: UPLOAD, pages: 5, jobs: [{ kind: "remask", state: "queued" }] });
    expect(d?.custody[0]).toMatchObject({ step: "collected", manifest: "M-ZZ-01", byName: "Ada Admin" });
    expect(d?.actions[0]).toMatchObject({ action: "script_page_rotated", reason: "Sideways" });
  });
  it("refuses a failure", () => {
    expect(parseScriptDetail({ ok: false, code: "not_found" })).toBeNull();
    expect(parseScriptDetail({ ok: true })).toBeNull();
  });
  it("knows what staff may still do", () => {
    expect(pagesEditable("verified")).toBe(true);
    expect(pagesEditable("ready_to_mark")).toBe(false);
    expect(pagesEditable("void")).toBe(false);
    expect(voidable("marking")).toBe(true);
    expect(voidable("final")).toBe(false);
    expect(voidable("void")).toBe(false);
    const up = parseScriptDetail(detail())!.uploads[0] as DetailUpload;
    expect(remaskPending(up)).toBe(true);
    expect(reprocessable(up, "verified")).toBe(true);
    expect(reprocessable(up, "marking")).toBe(false);
    expect(reprocessable({ ...up, state: "queued" }, "verified")).toBe(false);
    expect(turnText(0)).toBe("");
    expect(turnText(90)).toContain("quarter turn right");
    expect(turnText(180)).toContain("half turn");
    expect(turnText(270)).toContain("quarter turn left");
  });
});

describe("the repository actions", () => {
  it("make the right calls", () => {
    expect(repoRpc(SCRIPT, { action: "rotate", pageId: PAGE, turns: -1, reason: " Sideways " })).toEqual({
      fn: "script_page_rotate", args: { p_page: PAGE, p_quarter_turns: -1, p_reason: "Sideways" },
    });
    expect(repoRpc(SCRIPT, { action: "reprocess", uploadId: UPLOAD, reason: "Read wrongly" })).toEqual({
      fn: "script_upload_reprocess", args: { p_upload: UPLOAD, p_reason: "Read wrongly" },
    });
    expect(repoRpc(SCRIPT, { action: "void", reason: "Copied" })).toEqual({ fn: "script_void", args: { p_script: SCRIPT, p_reason: "Copied" } });
    expect(repoRpc(SCRIPT, { action: "remove", copyPage: 3, reason: "Old version" })).toEqual({
      fn: "script_page_remove", args: { p_script: SCRIPT, p_copy_page: 3, p_reason: "Old version" },
    });
  });
  it("say what happened", () => {
    expect(repoDoneMessage({ action: "rotate", pageId: PAGE, turns: 1, reason: "x" })).toContain("marking picture is being made again");
    expect(repoDoneMessage({ action: "reprocess", uploadId: UPLOAD, reason: "x" })).toContain("processed again");
    expect(repoDoneMessage({ action: "void", reason: "x" })).toContain("void");
    expect(repoDoneMessage({ action: "remove", copyPage: 3, reason: "x" })).toContain("Page 3");
    expect(repoFailureMessage({ code: "script_locked" })).toContain("being marked");
    expect(repoFailureMessage({ code: "conflict", reason: "busy" })).toContain("already waiting");
    expect(repoFailureMessage({})).toBe("Something went wrong. Please try again.");
  });
});
