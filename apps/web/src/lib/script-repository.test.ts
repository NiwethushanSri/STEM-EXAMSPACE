import { describe, expect, it } from "vitest";
import {
  SCRIPT_STATES,
  STATE_LABEL,
  actionText,
  beingMarked,
  handBackBlocked,
  picturesToCheckText,
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
  reprocessRefusal,
  stateText,
  takenBackReasonText,
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
    // Ruling R36: the detail says per file whether it may be processed again; the control is disabled with the reason.
    expect(up.reprocessRefused).toBeNull();
    expect(reprocessRefusal(up, "verified")).toBeNull();
    const d = detail();
    const worked = parseScriptDetail({ ...d, uploads: [{ ...d.uploads[0], reprocess_refused: "hidden_areas" }] })!.uploads[0] as DetailUpload;
    expect(worked.reprocessRefused).toBe("hidden_areas");
    expect(reprocessRefusal(worked, "verified")).toBe(
      "Staff have worked on pages of this file, so reprocessing it would undo that work and is not allowed.",
    );
    expect(reprocessRefusal({ ...worked, reprocessRefused: "extra_page" }, "needs_attention")).toContain("Staff have worked on pages");
    expect(reprocessRefusal({ ...worked, reprocessRefused: "script_locked" }, "verified")).toContain("being marked");
    // Not at rest, or the script itself being marked: no control at all, so no reason either.
    expect(reprocessRefusal({ ...worked, state: "queued" }, "verified")).toBeNull();
    expect(reprocessRefusal(worked, "marking")).toBeNull();
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
    // Voiding a final script: results are out, which is why it cannot be voided (not "being marked").
    expect(repoFailureMessage({ code: "script_locked" }, "void")).toContain("results are out");
    expect(repoFailureMessage({ code: "script_locked" }, "rotate")).toContain("being marked");
    // Ruling R35: a file staff have worked on is not processed again.
    expect(repoFailureMessage({ code: "staff_changes", reason: "hidden_areas" }, "reprocess")).toBe(
      "Staff have worked on pages of this file, so reprocessing it would undo that work and is not allowed.",
    );
  });
});

describe("taking a script back from the markers", () => {
  const takenBack = (state: string, jobs: unknown[] = [], reason = "name_visible") => {
    const d = detail();
    return parseScriptDetail({
      ...d,
      script: { ...d.script, state, taken_back_at: "2031-08-05T09:00:00Z", taken_back_reason: reason },
      uploads: [{ ...d.uploads[0], jobs }],
    })!;
  };
  it("reads when and why the script was taken back", () => {
    const d = takenBack("needs_attention");
    expect(d.script).toMatchObject({ takenBackAt: "2031-08-05T09:00:00Z", takenBackReason: "name_visible" });
    expect(parseScriptDetail(detail())!.script).toMatchObject({ takenBackAt: null, takenBackReason: null });
    expect(takenBackReasonText("name_visible")).toBe("A marker reported a visible name.");
    expect(takenBackReasonText("Check the pages")).toBe("Check the pages");
    expect(takenBackReasonText(null)).toBe("");
    expect(actionText("marking_script_taken_back")).toBe("Taken back from the markers");
    expect(actionText("marking_script_handed_back")).toBe("Handed back to the markers");
  });
  it("knows which scripts are with the markers", () => {
    expect(["ready_to_mark", "marking", "marked", "checked"].every((s) => beingMarked(s as never))).toBe(true);
    expect(["verified", "needs_attention", "final", "void"].some((s) => beingMarked(s as never))).toBe(false);
  });
  it("says in words why a script cannot be handed back yet", () => {
    expect(handBackBlocked(takenBack("needs_attention"))).toBe(
      "The script must be verified before it goes back to the markers. Settle its open problems first.",
    );
    expect(handBackBlocked(takenBack("checking"))).toContain("must be verified");
    const remask = [{ id: 9, kind: "remask", state: "queued", attempts: 0, last_error: null, created_at: null, finished_at: null }];
    expect(handBackBlocked(takenBack("verified", remask))).toBe("Its marking pictures are being made again. Hand it back when they are ready.");
    expect(handBackBlocked(takenBack("verified", [{ ...remask[0], kind: "prepare", state: "running" }]))).toContain("being made again");
    expect(handBackBlocked(takenBack("verified", [{ ...remask[0], state: "done" }]))).toBeNull();
    // Not taken back: there is nothing to hand back.
    expect(handBackBlocked(parseScriptDetail(detail())!)).toBeNull();
  });
  it("says when a marking picture check is what keeps it back (Phase 3A Task 8)", () => {
    const waiting = (n: number, exceptions: unknown[] = []) => {
      const d = detail();
      return parseScriptDetail({
        ...d,
        script: { ...d.script, state: "needs_attention", taken_back_at: "2031-08-05T09:00:00Z", taken_back_reason: "Check", pictures_to_check: n },
        uploads: [{ ...d.uploads[0], jobs: [] }],
        exceptions,
      })!;
    };
    expect(waiting(1).script.picturesToCheck).toBe(1);
    expect(parseScriptDetail(detail())!.script.picturesToCheck).toBe(0);
    expect(handBackBlocked(waiting(1))).toBe("A marking picture waits for a check under Marking pictures to check.");
    expect(handBackBlocked(waiting(2))).toBe("2 marking pictures wait for a check under Marking pictures to check.");
    expect(picturesToCheckText(0)).toBeNull();
    // An open problem keeps it from verified first: settle that.
    const open = { id: "e1", kind: "poor_quality", state: "open", created_at: "2031-08-04T11:00:00Z", details: {} };
    expect(handBackBlocked(waiting(1, [open]))).toContain("Settle its open problems first");
    expect(handBackBlocked(waiting(0))).toContain("Settle its open problems first");
  });
  it("makes the calls and says what happened", () => {
    expect(repoRpc(SCRIPT, { action: "take_back", reason: " Place a page " })).toEqual({
      fn: "marking_script_take_back", args: { p_script: SCRIPT, p_reason: "Place a page" },
    });
    expect(repoRpc(SCRIPT, { action: "hand_back", reason: "  " })).toEqual({ fn: "marking_script_hand_back", args: { p_script: SCRIPT, p_reason: null } });
    expect(repoRpc(SCRIPT, { action: "hand_back", reason: "Name hidden" })).toEqual({
      fn: "marking_script_hand_back", args: { p_script: SCRIPT, p_reason: "Name hidden" },
    });
    expect(repoDoneMessage({ action: "take_back", reason: "x" })).toBe("The script is taken back from the markers. Its pages can be changed now.");
    expect(repoDoneMessage({ action: "hand_back", reason: "" })).toBe("The script is handed back to the markers.");
    expect(repoFailureMessage({ code: "conflict", reason: "not_verified" }, "hand_back")).toContain("must be verified");
    expect(repoFailureMessage({ code: "conflict", reason: "pictures_updating" }, "hand_back")).toContain("being made again");
    expect(repoFailureMessage({ code: "conflict", reason: "taken_back" }, "take_back")).toContain("already taken back");
  });
});
