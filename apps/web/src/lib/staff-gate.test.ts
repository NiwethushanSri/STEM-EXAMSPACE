import { beforeEach, describe, expect, it, vi } from "vitest";

// The teacher's and corrector's layouts ask the database once whether the marker leads a subject (3B Task 13: the light
// marking_is_lead, not the whole of marking_my_work), so their menus show Review under Marking.
const state = vi.hoisted(() => ({ role: "corrector", answer: { data: true as unknown, error: null as { message: string } | null } }));
const rpc = vi.hoisted(() => vi.fn());

vi.mock("next/navigation", () => ({ redirect: vi.fn(() => { throw new Error("NEXT_REDIRECT"); }) }));
vi.mock("@/components/AppShell", () => ({ ShellUserProvider: () => null }));
vi.mock("@/lib/supabase/server", () => ({
  createClient: async () => ({ rpc }),
  getSessionProfile: async () => ({ id: "u1", role: state.role, status: "active", firstName: "Ann", lastName: "Marker" }),
}));

const { StaffLayout } = await import("./staff-gate");

/** The user the layout gives the shell. */
async function shellUser(allowed: string[]): Promise<{ name: string; lead?: boolean }> {
  const el = (await StaffLayout({ allowed: allowed as never, markingMenu: true, children: null })) as { props: { user: { name: string; lead?: boolean } } };
  return el.props.user;
}

beforeEach(() => {
  rpc.mockReset();
  rpc.mockImplementation(async () => state.answer);
  state.role = "corrector";
  state.answer = { data: true, error: null };
});

describe("StaffLayout's lead flag", () => {
  it("lead_flag_from_marking_is_lead: asks marking_is_lead once, and nothing else", async () => {
    expect(await shellUser(["corrector"])).toMatchObject({ name: "Ann Marker", lead: true });
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(rpc).toHaveBeenCalledWith("marking_is_lead");
  });

  it("is false when the marker does not lead, or the answer cannot be read", async () => {
    state.answer = { data: false, error: null };
    expect((await shellUser(["corrector"])).lead).toBe(false);
    state.answer = { data: null, error: { message: "down" } };
    expect((await shellUser(["corrector"])).lead).toBe(false);
    state.answer = { data: "yes", error: null };
    expect((await shellUser(["corrector"])).lead).toBe(false);
  });

  it("asks nothing for a role that does not mark", async () => {
    state.role = "tutor";
    expect((await shellUser(["tutor"])).lead).toBe(false);
    expect(rpc).not.toHaveBeenCalled();
  });
});
