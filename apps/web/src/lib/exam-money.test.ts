import { describe, expect, it } from "vitest";
import { examMoney } from "./exam-money";

const PAID = "2026-01-01T10:00:00Z";

describe("examMoney", () => {
  it("counts every booking with paid_at set, whatever its status", () => {
    const rows = [
      { amount_pence: 1000, refunded_pence: 0, paid_at: PAID }, // paid / cancel_requested
      { amount_pence: 2000, refunded_pence: 0, paid_at: PAID }, // cancelled, money kept
      { amount_pence: 1500, refunded_pence: 1500, paid_at: PAID }, // refunded
      { amount_pence: 3000, refunded_pence: 1000, paid_at: PAID }, // part_refunded
      { amount_pence: 900, refunded_pence: 0, paid_at: null }, // awaiting payment
    ];
    expect(examMoney(rows)).toEqual({ taken: 7500, refunded: 2500, net: 5000 });
  });

  it("is zero with no paid bookings", () => {
    expect(examMoney([{ amount_pence: 500, refunded_pence: 0, paid_at: null }])).toEqual({ taken: 0, refunded: 0, net: 0 });
  });
});
