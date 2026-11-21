import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));
vi.mock("@/lib/staff-gate", () => ({ requireStaff: vi.fn(async () => ({})) }));

const rpc = vi.fn();
vi.mock("@/lib/supabase/server", () => ({ createClient: async () => ({ rpc }) }));

import { scriptRepositoryAction } from "@/app/admin/scripts/[id]/actions";
import { savePageLayoutAction } from "@/app/admin/exams/[id]/actions";

const SCRIPT = "11111111-1111-4111-8111-111111111111";
const PAGE = "22222222-2222-4222-8222-222222222222";
const UPLOAD = "33333333-3333-4333-8333-333333333333";
const EXAM = "44444444-4444-4444-8444-444444444444";
const PAPER = "55555555-5555-4555-8555-555555555555";

beforeEach(() => rpc.mockReset());

describe("script repository actions", () => {
  it("turns a page with the reason", async () => {
    rpc.mockResolvedValue({ data: { ok: true, rotation: 90, queued: true }, error: null });
    const r = await scriptRepositoryAction(SCRIPT, { action: "rotate", pageId: PAGE, turns: 1, reason: "Scanned sideways" });
    expect(r.ok).toBe(true);
    expect(rpc).toHaveBeenCalledWith("script_page_rotate", { p_page: PAGE, p_quarter_turns: 1, p_reason: "Scanned sideways" });
  });

  it("asks for a reason before calling the database", async () => {
    const r = await scriptRepositoryAction(SCRIPT, { action: "void", reason: " a " });
    expect(r).toEqual({ ok: false, message: "Give a reason of 3 to 300 characters." });
    expect(rpc).not.toHaveBeenCalled();
  });

  it("refuses ids and turns that are not ones", async () => {
    expect((await scriptRepositoryAction("nope", { action: "void", reason: "Copied work" })).ok).toBe(false);
    expect((await scriptRepositoryAction(SCRIPT, { action: "rotate", pageId: "x", turns: 1, reason: "Sideways" })).ok).toBe(false);
    expect((await scriptRepositoryAction(SCRIPT, { action: "rotate", pageId: PAGE, turns: 3 as 1, reason: "Sideways" })).ok).toBe(false);
    expect((await scriptRepositoryAction(SCRIPT, { action: "remove", copyPage: 0, reason: "Old version" })).ok).toBe(false);
    expect((await scriptRepositoryAction(SCRIPT, { action: "reprocess", uploadId: "u", reason: "Read wrongly" })).ok).toBe(false);
    expect(rpc).not.toHaveBeenCalled();
  });

  it("says why the database refused", async () => {
    rpc.mockResolvedValue({ data: { ok: false, code: "conflict", reason: "busy" }, error: null });
    const r = await scriptRepositoryAction(SCRIPT, { action: "reprocess", uploadId: UPLOAD, reason: "Read wrongly" });
    expect(r.ok).toBe(false);
    expect(r.message).toContain("already waiting");
    rpc.mockResolvedValue({ data: null, error: { message: "boom" } });
    expect(await scriptRepositoryAction(SCRIPT, { action: "remove", copyPage: 2, reason: "Old version" })).toEqual({
      ok: false, message: "Something went wrong. Please try again.",
    });
  });
});

describe("saving a paper's page layout", () => {
  const layout = (reviewedAt: string | null) => ({
    data: { ok: true, pages: [{ page: 1, role: "cover" }, { page: 2, role: "answer" }], areas: [], reviewed_at: reviewedAt },
    error: null,
  });
  const answers = (reviewedAt: string | null) =>
    rpc.mockImplementation(async (name: string) =>
      name === "paper_page_layout" ? layout(reviewedAt) : { data: { ok: true, changed_pages: [2] }, error: null },
    );
  const areas = [{ page: 2, x: 0.1, y: 0.2, w: 0.3, h: 0.05 }];

  it("sends only the areas when the roles have not changed (scripts may already exist)", async () => {
    answers("2031-08-01T10:00:00Z");
    const r = await savePageLayoutAction(EXAM, PAPER, [{ page: 1, role: "cover" }, { page: 2, role: "answer" }], areas);
    expect(r).toMatchObject({ ok: true, changedPages: [2] });
    expect(rpc.mock.calls.map((c) => c[0])).toEqual(["paper_page_layout", "set_paper_hidden_areas"]);
  });

  it("sends the roles when they changed", async () => {
    answers("2031-08-01T10:00:00Z");
    await savePageLayoutAction(EXAM, PAPER, [{ page: 1, role: "answer" }, { page: 2, role: "answer" }], areas);
    expect(rpc.mock.calls.map((c) => c[0])).toEqual(["paper_page_layout", "set_paper_page_roles", "set_paper_hidden_areas"]);
  });

  it("sends the roles to confirm them while they have not been checked", async () => {
    answers(null);
    await savePageLayoutAction(EXAM, PAPER, [{ page: 1, role: "cover" }, { page: 2, role: "answer" }], areas);
    expect(rpc.mock.calls.map((c) => c[0])).toEqual(["paper_page_layout", "set_paper_page_roles", "set_paper_hidden_areas"]);
  });
});
