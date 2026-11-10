export type MoneyBooking = { amount_pence: number; refunded_pence: number; paid_at: string | null };

/** Same rule as Finance (money_totals): every booking with paid_at set counts as taken. */
export function examMoney(bookings: MoneyBooking[]): { taken: number; refunded: number; net: number } {
  let taken = 0;
  let refunded = 0;
  for (const b of bookings) {
    if (b.paid_at === null) continue;
    taken += b.amount_pence;
    refunded += b.refunded_pence;
  }
  return { taken, refunded, net: taken - refunded };
}
