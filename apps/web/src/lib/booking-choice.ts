import { isUuid } from "./uuid";

export type SittingMode = "centre" | "home";

/** What the booking form says about where the student sits. Both are null when the form asks nothing extra. */
export type BookingChoice = { ok: true; sitting: SittingMode | null; centre: string | null } | { ok: false };

/** Reads the optional sitting and centre of the booking form. The database re-checks whether they are allowed. */
export function parseBookingChoice(form: FormData): BookingChoice {
  const sitting = String(form.get("sitting") ?? "");
  const centre = String(form.get("centre") ?? "");
  if (sitting && sitting !== "centre" && sitting !== "home") return { ok: false };
  if (centre && !isUuid(centre)) return { ok: false };
  return { ok: true, sitting: (sitting || null) as SittingMode | null, centre: centre || null };
}
