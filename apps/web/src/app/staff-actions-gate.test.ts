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
const structure = vi.hoisted(() => ({
  saveStructure: vi.fn(),
  beginMarkSchemeFile: vi.fn(),
  markSchemeFileStored: vi.fn(),
  removeMarkSchemeFile: vi.fn(),
}));
vi.mock("@/lib/exam-structure-server", () => structure);
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
  for (const f of Object.values(structure)) f.mockClear();
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

describe("questions and mark scheme actions", () => {
  const draft = { groups: [], option_groups: [], questions: [] };
  it("the admin ones are refused for a teacher and touch nothing", async () => {
    const a = await import("./admin/exams/[id]/actions");
    await expect(a.saveStructureAction(UUID, draft, "Reason")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.markSchemeBeginAction(UUID, 1000)).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.markSchemeStoredAction(UUID, UUID)).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.markSchemeRemoveAction(UUID, UUID, "Wrong file")).rejects.toThrow("NEXT_REDIRECT");
    expect(state.calls.every((c) => c.join() === "admin,owner")).toBe(true);
    expect(state.calls).toHaveLength(4);
    expect(Object.values(structure).some((f) => f.mock.calls.length > 0)).toBe(false);
  });
  it("the marking open and close ones are refused for a teacher and touch nothing", async () => {
    const a = await import("./admin/exams/[id]/actions");
    await expect(a.saveMarkingSettingsAction(UUID, { mode: "whole", deadlineDate: "", deadlineTime: "" })).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.openMarkingAction(UUID)).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.closeMarkingAction(UUID, "Marking is finished")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.reopenMarkingAction(UUID, "More scripts came in")).rejects.toThrow("NEXT_REDIRECT");
    expect(state.calls.every((c) => c.join() === "admin,owner")).toBe(true);
    expect(state.calls).toHaveLength(4);
    expect(createClient).not.toHaveBeenCalled();
  });
  it("the teacher ones are refused for an admin and touch nothing", async () => {
    state.role = "admin";
    const t = await import("./teacher/exams/actions");
    await expect(t.saveTeacherStructureAction(UUID, draft)).rejects.toThrow("NEXT_REDIRECT");
    await expect(t.teacherMarkSchemeBeginAction(UUID, 1000)).rejects.toThrow("NEXT_REDIRECT");
    await expect(t.teacherMarkSchemeStoredAction(UUID, UUID)).rejects.toThrow("NEXT_REDIRECT");
    await expect(t.teacherMarkSchemeRemoveAction(UUID, UUID, "Wrong file")).rejects.toThrow("NEXT_REDIRECT");
    expect(state.calls.every((c) => c.join() === "teacher")).toBe(true);
    expect(state.calls).toHaveLength(4);
    expect(Object.values(structure).some((f) => f.mock.calls.length > 0)).toBe(false);
  });
});

describe("marking actions", () => {
  it("the marker and lead ones are refused for a tutor and touch nothing", async () => {
    state.role = "tutor";
    const m = await import("./marking/actions");
    await expect(m.nextScript(UUID)).rejects.toThrow("NEXT_REDIRECT");
    await expect(m.nextScript(UUID, UUID)).rejects.toThrow("NEXT_REDIRECT");
    await expect(m.giveBack(UUID)).rejects.toThrow("NEXT_REDIRECT");
    await expect(m.releaseAlert(UUID, "Pictures checked")).rejects.toThrow("NEXT_REDIRECT");
    await expect(m.noteAlert(UUID, "Seen it")).rejects.toThrow("NEXT_REDIRECT");
    await expect(m.releaseAllAlerts(UUID, "All checked")).rejects.toThrow("NEXT_REDIRECT");
    await expect(m.markingFeedback(UUID)).rejects.toThrow("NEXT_REDIRECT");
    expect(state.calls).toHaveLength(7);
    expect(state.calls.every((c) => c.join() === "corrector,teacher,admin,owner")).toBe(true);
    expect(createClient).not.toHaveBeenCalled();
  });
  it("the admin ones are refused for a corrector (a lead marker too) and touch nothing", async () => {
    state.role = "corrector";
    const a = await import("./admin/marking/actions");
    await expect(a.assignUnits([UUID], UUID, "Cover for Ann")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.assignSome(UUID, null, UUID, 5, "Even the load")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.takeBackUnits([UUID], "Marked wrongly")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.reassignUnits([UUID], UUID, "Marked wrongly")).rejects.toThrow("NEXT_REDIRECT");
    expect(state.calls).toHaveLength(4);
    expect(state.calls.every((c) => c.join() === "admin,owner")).toBe(true);
    expect(createClient).not.toHaveBeenCalled();
  });
  it("the lead's review ones are refused for a tutor and touch nothing", async () => {
    state.role = "tutor";
    const r = await import("./marking/review/actions");
    const marks = [{ question_id: UUID, mark: 1, na: false }];
    await expect(r.settleReview(UUID, "first_stands", 1, 1, "Agreed with the first")).rejects.toThrow("NEXT_REDIRECT");
    await expect(r.settleReview(UUID, "lead_marks", 1, 1, "My own view", marks)).rejects.toThrow("NEXT_REDIRECT");
    await expect(r.acceptReview(UUID)).rejects.toThrow("NEXT_REDIRECT");
    await expect(r.sendBack(UUID, "same", "Look at 2(b) again.", "Too generous")).rejects.toThrow("NEXT_REDIRECT");
    await expect(r.sampleMarker(UUID, UUID, 5)).rejects.toThrow("NEXT_REDIRECT");
    await expect(r.setFinalMarks(UUID, marks, "Misread 1(a)")).rejects.toThrow("NEXT_REDIRECT");
    await expect(r.setFinalMarks(UUID, marks, "Misread 1(a)", UUID)).rejects.toThrow("NEXT_REDIRECT");
    await expect(r.clearMarker(UUID, UUID, "Practice is good")).rejects.toThrow("NEXT_REDIRECT");
    await expect(r.pauseMarker(UUID, UUID, "Too many misses")).rejects.toThrow("NEXT_REDIRECT");
    await expect(r.setStandard(UUID, "practice")).rejects.toThrow("NEXT_REDIRECT");
    await expect(r.retireStandard(UUID, "No longer fair")).rejects.toThrow("NEXT_REDIRECT");
    expect(state.calls).toHaveLength(11);
    expect(state.calls.every((c) => c.join() === "corrector,teacher,admin,owner")).toBe(true);
    expect(createClient).not.toHaveBeenCalled();
  });
  it("the admin second-marking ones are refused for a corrector (a lead marker too) and touch nothing", async () => {
    state.role = "corrector";
    const a = await import("./admin/marking/actions");
    await expect(a.addSecond([UUID], "A second look")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.dropSecond([UUID], "Nobody can take it")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.assignSecond([UUID], UUID, "Cover for Ann")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.takeBackSecond([UUID], "Marked wrongly")).rejects.toThrow("NEXT_REDIRECT");
    expect(state.calls).toHaveLength(4);
    expect(state.calls.every((c) => c.join() === "admin,owner")).toBe(true);
    expect(createClient).not.toHaveBeenCalled();
  });
});

describe("attendance actions called by a student or parent", () => {
  it("every attendance action is refused and touches nothing", async () => {
    state.role = "student";
    const a = await import("@/components/attendance/actions");
    await expect(a.lookupAction(UUID, "SE-2026-0001")).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.markAction(UUID, UUID)).rejects.toThrow("NEXT_REDIRECT");
    await expect(a.closeRegisterAction(UUID)).rejects.toThrow("NEXT_REDIRECT");
    expect(state.calls).toHaveLength(3);
    expect(state.calls.every((c) => c.join() === "admin,owner,teacher")).toBe(true);
    expect(createClient).not.toHaveBeenCalled();
  });
});
