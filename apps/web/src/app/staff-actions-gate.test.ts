import { beforeEach, describe, expect, it, vi } from "vitest";

// A signed-in teacher (or anyone outside the allowed roles) calling a staff server action directly must be
// stopped by requireStaff before any database client is created. requireStaff is mocked to behave like the
// real one: it redirects (throws) when the caller's role is not in the allowed list.
const state = vi.hoisted(() => ({ role: "teacher", calls: [] as string[][] }));
const createClient = vi.hoisted(() => vi.fn());

vi.mock("@/lib/staff-gate", () => ({
  requireStaff: async (roles: string[]) => {
    state.calls.push(roles);
    if (!roles.includes(state.role)) throw new Error("NEXT_REDIRECT");
    return { id: "u1", role: state.role, status: "active", firstName: "T", lastName: "T" };
  },
}));
vi.mock("@/lib/supabase/server", () => ({ createClient }));
vi.mock("@/lib/exam-rpc", () => ({ callSaveExam: vi.fn(), explainSaveConflict: vi.fn(), readRpc: vi.fn() }));
vi.mock("@/lib/bookings-admin", () => ({ searchStudents: vi.fn() }));
vi.mock("next/cache", () => ({ revalidatePath: vi.fn() }));

const raw = {
  subject: "1",
  title: "T",
  format: "online",
  startDate: "2030-06-12",
  startTime: "09:00",
  deadlineDate: "2030-06-10",
  deadlineTime: "09:00",
  duration: "60",
  seats: "5",
  price: "5",
};
const UUID = "11111111-2222-3333-4444-555555555555";

beforeEach(() => {
  state.role = "teacher";
  state.calls.length = 0;
  createClient.mockClear();
});

describe("admin staff actions called directly by a teacher", () => {
  it("saveExamAction is refused and touches nothing", async () => {
    const { saveExamAction } = await import("./admin/exams/actions");
    await expect(saveExamAction(raw)).rejects.toThrow("NEXT_REDIRECT");
    expect(state.calls[0]).toEqual(["admin", "owner"]);
    expect(createClient).not.toHaveBeenCalled();
  });
  it("setExamStatusAction is refused and touches nothing", async () => {
    const { setExamStatusAction } = await import("./admin/exams/actions");
    await expect(setExamStatusAction(UUID, "published")).rejects.toThrow("NEXT_REDIRECT");
    await expect(setExamStatusAction(UUID, "cancelled")).rejects.toThrow("NEXT_REDIRECT");
    expect(createClient).not.toHaveBeenCalled();
  });
  it("saveVenueAction is refused and touches nothing", async () => {
    const { saveVenueAction } = await import("./admin/venues/actions");
    await expect(saveVenueAction({ id: "", name: "V", rooms: "A", active: true })).rejects.toThrow("NEXT_REDIRECT");
    expect(createClient).not.toHaveBeenCalled();
  });
});

describe("admin booking actions called directly by a teacher", () => {
  it("every booking action is refused and touches nothing", async () => {
    const a = await import("./admin/bookings/actions");
    await expect(a.addBookingAction(UUID, UUID, true, "")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.markPaidAction(UUID, "")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.cancelBookingAction(UUID, "")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.decideCancellationAction(UUID, true, "1", "")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.decideCancellationAction(UUID, false, "0", "")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.searchStudentsAction("ada")).rejects.toThrow("NEXT_REDIRECT");
    expect(state.calls.every((c) => c.join() === "admin,owner")).toBe(true);
    expect(state.calls).toHaveLength(6);
    expect(createClient).not.toHaveBeenCalled();
  });
});

describe("teacher action called by an admin", () => {
  it("is refused too", async () => {
    state.role = "admin";
    const { saveTeacherExamAction } = await import("./teacher/exams/actions");
    await expect(saveTeacherExamAction(raw)).rejects.toThrow("NEXT_REDIRECT");
    expect(state.calls[0]).toEqual(["teacher"]);
    expect(createClient).not.toHaveBeenCalled();
  });
});
