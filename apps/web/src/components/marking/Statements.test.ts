import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { Statements as MonthStatements } from "@/lib/marker-pay";

vi.mock("next/navigation", () => ({ useRouter: () => ({ refresh: vi.fn() }), usePathname: () => "/admin/marking/payments" }));
vi.mock("@/lib/supabase/client", () => ({ createClient: vi.fn() }));
vi.mock("@/app/admin/marking/payments/actions", () => ({ fixMonth: vi.fn(), exportCsv: vi.fn() }));

const { Statements } = await import("./Statements");

const picker = { ended: ["2027-03", "2027-02"], current: "2027-04" };
const base: MonthStatements = {
  month: "2027-03",
  ended: true,
  fixed: false,
  rateMissing: [],
  markers: [
    {
      markerId: "m1",
      name: "Ann Archer",
      fixedAt: "2027-04-01T23:30:00Z",
      pieces: 2,
      totalPence: 2500,
      lines: [{ examId: "e1", examTitle: "Maths", paper: "Paper 1", groupLabel: null, kind: "live", pieces: 2, ratePence: 1250, pence: 2500 }],
    },
    {
      markerId: "m2",
      name: "Bob Baker",
      fixedAt: null,
      pieces: 5,
      totalPence: null,
      lines: [
        { examId: "e1", examTitle: "Maths", paper: "Paper 1", groupLabel: "Section A", kind: "second", pieces: 1, ratePence: 1250, pence: 1250 },
        { examId: "e2", examTitle: "Physics", paper: "Paper 2", groupLabel: null, kind: "remark", pieces: 4, ratePence: null, pence: null },
      ],
    },
  ],
};
const render = (statements: MonthStatements) => renderToStaticMarkup(createElement(Statements, { statements, picker }));

describe("Statements", () => {
  it("statements_show_lines_totals_and_whether_fixed", () => {
    const html = render(base);
    expect(html).toContain("March 2027");
    expect(html).toContain("Ann Archer");
    expect(html).toContain("Fixed on 2 April 2027");
    expect(html).toContain("Not fixed yet. These figures can still change.");
    expect(html).toContain("First marking");
    expect(html).toContain("Second marking");
    expect(html).toContain("Re-marking");
    expect(html).toContain("£12.50");
    expect(html).toContain("£25.00");
    expect(html).toContain("Download CSV");
    expect(html).toContain("Practice and seeded scripts are not paid. Paying markers happens outside this system.");
  });

  it("statements_never_show_a_pound_figure_for_an_unknown_amount", () => {
    const html = render(base);
    expect(html).toContain("Rate not set");
    expect(html).not.toContain("£0.00");
    // Bob's total is unknown while a line has no rate: no total amount for him.
    const bob = html.slice(html.indexOf("Bob Baker"));
    expect(bob).not.toContain("£37.50");
    expect(bob).not.toMatch(/Total[^£]*£/);
  });

  it("statements_fix_is_off_until_the_month_has_ended", () => {
    const html = render({ ...base, month: "2027-04", ended: false });
    expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Fix this month&#x27;s statements<\/button>/);
    expect(html).toContain("This month has not ended yet.");
    expect(render(base)).not.toMatch(/<button[^>]*disabled=""[^>]*>Fix this month&#x27;s statements<\/button>/);
  });

  it("statements_name_the_exams_without_a_rate", () => {
    const html = render({ ...base, rateMissing: [{ examId: "11111111-2222-3333-4444-555555555555", title: "Physics", paper: "Paper 2" }] });
    expect(html).toContain("Physics (Paper 2)");
    expect(html).toContain('href="/admin/exams/11111111-2222-3333-4444-555555555555"');
  });

  it("statements_of_a_month_with_nothing_to_pay", () => {
    const html = render({ ...base, markers: [] });
    expect(html).toContain("There is no marking to pay for March 2027.");
    expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Fix this month&#x27;s statements<\/button>/);
    expect(html).toMatch(/<button[^>]*disabled=""[^>]*>Download CSV<\/button>/);
  });

  it("statements_month_picker_starts_with_the_last_ended_month", () => {
    const html = render(base);
    const options = [...html.matchAll(/<option value="([^"]+)"/g)].map((m) => m[1]);
    expect(options).toEqual(["2027-03", "2027-02", "2027-04"]);
    expect(html).toMatch(/<option value="2027-03" selected="">/);
  });
});
