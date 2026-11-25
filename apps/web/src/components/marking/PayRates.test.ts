import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import type { RatesView } from "@/lib/marker-pay";

vi.mock("next/navigation", () => ({ useRouter: () => ({ refresh: vi.fn() }), usePathname: () => "/admin/exams/x" }));
vi.mock("@/lib/supabase/client", () => ({ createClient: vi.fn() }));
vi.mock("@/app/admin/marking/payments/actions", () => ({ setRates: vi.fn() }));

const { PayRates } = await import("./PayRates");

const EXAM = "11111111-2222-3333-4444-555555555555";
const render = (rates: RatesView | null) => renderToStaticMarkup(createElement(PayRates, { examId: EXAM, rates }));

describe("PayRates", () => {
  it("pay_rates_whole_script_has_one_box", () => {
    const html = render({ mode: "whole", rates: [{ groupId: null, label: null, pence: 1250 }], fixedPieces: 0 });
    expect(html).toContain("Marker pay");
    expect(html).toContain("Pay per script");
    expect(html.match(/<input/g)).toHaveLength(1);
    expect(html).toContain('value="12.50"');
    expect(html).not.toContain("reason");
  });

  it("pay_rates_by_question_has_a_box_per_group", () => {
    const html = render({
      mode: "by_question",
      rates: [
        { groupId: "g1", label: "Section A", pence: null },
        { groupId: "g2", label: "Section B", pence: 300 },
      ],
      fixedPieces: 0,
    });
    expect(html.match(/<input/g)).toHaveLength(2);
    expect(html).toContain("Section A");
    expect(html).toContain("Section B");
    expect(html).toContain('value="3.00"');
    expect(html).toContain("No rate is set yet.");
  });

  it("pay_rates_ask_for_a_reason_once_pieces_are_fixed", () => {
    const html = render({ mode: "whole", rates: [{ groupId: null, label: null, pence: 1250 }], fixedPieces: 4 });
    expect(html).toContain("a change needs a reason");
  });

  it("pay_rates_that_could_not_be_loaded", () => {
    expect(render(null)).toContain("The pay rates could not be loaded. Refresh the page.");
  });
});
