import type { Database } from "@stem/shared";

export type BookingStatus = Database["public"]["Enums"]["booking_status"];

export const STATUS_LABEL: Record<BookingStatus, string> = {
  awaiting_payment: "Awaiting payment",
  paid: "Paid",
  cancel_requested: "Cancellation requested",
  refunded: "Refunded",
  part_refunded: "Partly refunded",
  cancelled: "Cancelled",
  expired: "Expired",
};

export const STATUS_TONE: Record<BookingStatus, "blue" | "green" | "amber" | "red" | "slate"> = {
  awaiting_payment: "amber",
  paid: "green",
  cancel_requested: "amber",
  refunded: "slate",
  part_refunded: "slate",
  cancelled: "slate",
  expired: "slate",
};

export const PAY_NOTE = "You will pay the institution directly — your booking is held until the booking deadline";
