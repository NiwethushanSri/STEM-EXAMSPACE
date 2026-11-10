# Stem Examspace Part 2: Exams, bookings, payments and attendance — Design

Date: 2026-11-10
Status: Draft for owner review
Builds on: `2026-11-07-crm-foundation-design.md` (Part 1). All Part 1 rules apply: row-level security on every table, all writes through checked SQL functions or Edge Functions, closed default privileges with explicit grants, audit rows written in the same transaction as the change, no personal data in logs.

## 1. Purpose

Replace the mock "Exams & timetable", "Bookings & payments" and "Attendance" pages with real features, so that the institution can publish mock exams, families can book and pay online, and staff can take attendance on the day.

Success: a parent or student books and pays for a published exam on the website; the seat is guaranteed only after Stripe confirms payment; admins see every booking and the money taken; staff take attendance by scanning the index card; refunds are handled by admins; no overbooking is possible.

Out of scope (Part 3/4): delivering online exam papers and collecting answers, marking, results, notices and reminders, push notifications, the mobile app. Online exams are bookable in Part 2 like in-person ones.

## 2. Owner decisions

| Topic | Decision |
|---|---|
| Booking model | One booking per exam, paid by card on the website (Stripe) |
| Who books | A signed-in parent for any linked child, or an active student for themselves |
| Exam setup | Full sitting details: subject, title, paper/level, date, start time, duration, format (in person at a venue/room, or online), seat limit, price, booking deadline, status |
| Attendance | Scan the QR on the student's index card or type the index number; photo and name shown to confirm; unscanned students become absent when the register closes |
| Refunds | Families request cancellation; an admin approves (full or partial refund via Stripe) or declines; exams cancelled by the institution refund every paid booking automatically |
| Teachers | Create and edit drafts for their own subjects; only admin/Super administrator set price and publish; teachers see bookings and attendance for their subjects |
| Payments | Stripe Checkout (hosted page) with a 30-minute seat hold; paid only via Stripe's signed webhook |

## 3. Data model

```
venues          id, name, rooms text[] , active, created_at
exams           id, subject_id → subjects, title, paper, format ('in_person' | 'online'),
                venue_id → venues (null for online), room, starts_at timestamptz,
                duration_minutes, seat_limit int > 0, price_pence int ≥ 0, currency 'gbp',
                booking_deadline timestamptz (≤ starts_at), status ('draft' | 'published' |
                'cancelled' | 'completed'), created_by → profiles, created_at, updated_at
bookings        id, exam_id → exams, student_id → profiles, booked_by → profiles,
                status ('reserved' | 'paid' | 'cancel_requested' | 'refunded' |
                'part_refunded' | 'cancelled' | 'expired'), amount_pence, refunded_pence,
                stripe_checkout_session_id, stripe_payment_intent_id, hold_expires_at,
                paid_offline boolean, created_at, updated_at
                unique (exam_id, student_id) where status in ('reserved','paid','cancel_requested')
attendance      exam_id, student_id, status ('present' | 'late' | 'absent'), marked_by, marked_at,
                primary key (exam_id, student_id)
stripe_events   id (Stripe event id, primary key), type, received_at, processed_at, outcome
```

- Seats taken = bookings in `reserved` (hold not expired), `paid`, `cancel_requested`.
- Teachers' subjects come from Part 1 `teacher_subjects`.
- All amounts are integers in pence. Currency is GBP.

## 4. Rules (enforced in SQL / Edge Functions)

- **Exam editing:** teacher may create/edit `draft` exams only for subjects in their `teacher_subjects`, and may not set `price_pence` or status. Owner/admin may create/edit any exam, set price, publish, cancel, complete. Published exams: changing date/venue/duration is allowed for admin (audit row); changing price only if no bookings exist; seat_limit cannot go below seats taken.
- **Booking (`create-booking` Edge Function):** caller is an active student booking for self, or an active parent booking for a linked child; target student must be `active`. In one locked transaction: exam must be `published`, now < booking_deadline, seats taken < seat_limit, no active booking for that student+exam. Insert `reserved` with `hold_expires_at = now() + 30 min`, then create a Stripe Checkout Session (mode payment, GBP, amount, `expires_at` = hold end, `client_reference_id` = booking id, metadata booking id, `customer_email` = payer's email so Stripe sends the receipt) and return its URL. Free exams (price 0) skip Stripe and become `paid` directly.
- **Expiry:** a scheduled job every 5 minutes marks expired holds `expired`; Stripe sessions expire at the same time.
- **Webhook (`stripe-webhook` Edge Function, no JWT):** verifies the Stripe signature with the webhook secret; records the event id in `stripe_events` and ignores duplicates. `checkout.session.completed` → booking `paid` (if the hold expired: take a seat if one is free, else refund in full and flag for admin). `charge.refunded` → update `refunded_pence` / status. Only this function marks bookings paid (besides admin offline payments and free exams).
- **Cancellation:** student/parent may request cancellation of a `paid` booking before the exam starts → `cancel_requested`. Admin approves (full or partial refund via Stripe Refunds API → `refunded`/`part_refunded`; seat released) or declines (back to `paid`). All audited.
- **Exam cancelled by institution:** every `paid`/`cancel_requested` booking is refunded in full automatically; `reserved` ones are cancelled.
- **Offline booking:** admin/owner may add a booking marked `paid_offline` (no Stripe), subject to the same seat checks.
- **Attendance:** owner/admin and teachers of the exam's subject may mark attendance for students with a `paid` booking. Present before `starts_at + 15 min`, late after. Closing the register marks every unmarked paid student `absent` and sets the exam `completed` (only after start time).
- **Read access (RLS):** published exams readable by any signed-in user (and by the public exams page via a safe read path showing no personal data); bookings: student own, parent linked children, tutor assigned students, teacher their subjects' exams, owner/admin all; attendance: same pattern; stripe_events: owner/admin only.
- **Money totals:** owner and admin see totals per exam and per month (paid minus refunded).

## 5. Screens

Families:
- `/exams` (public): published exams with subject filter, date/time, venue or "Online", duration, price, seats left, booking deadline. "Book" goes to sign-in if needed.
- Booking page: parent chooses which linked child; shows exam details and price → Stripe Checkout → `/bookings/success?booking=…` (shows status from the database, polls briefly until the webhook marks it paid) or `/bookings/cancelled`.
- "My bookings" section on student and parent account pages: upcoming and past bookings with status, "Request cancellation", and the index card (student only) to print.

Staff:
- `/admin/exams`: list with filters; create/edit form; publish/cancel/complete; per-exam seats sold and money taken. Teachers get `/teacher/exams` (own subjects, drafts only).
- `/admin/bookings`: all bookings with filters; add offline booking; cancellation requests with approve (full/partial) / decline; refunds history.
- `/admin/venues`: manage venues and rooms.
- `/admin/attendance`: choose an exam → register page with camera QR scanning (browser camera API) or typed index number; shows photo (signed URL) + name to confirm; mark present/late; close register; "attendance not marked" list.
- `/admin/finance` (owner and admin): totals per exam and per month.
- Index cards: printable A6 card per student (name, index number, QR of the index number only, photo), from the student's admin row and the student's account page.
- Teacher, tutor and corrector homes: real lists (teacher: own exams and their bookings counts; tutor: assigned students' upcoming bookings; corrector: placeholder until Part 3).

## 6. Stripe setup (owner)

- Owner creates a Stripe account (test mode first), and sets `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` as Edge Function secrets themselves (Claude never handles them). Webhook endpoint: `<SUPABASE_URL>/functions/v1/stripe-webhook`, events `checkout.session.completed`, `checkout.session.expired`, `charge.refunded`.
- Stripe sends payment and refund receipts by email, so these work before Resend is set up.
- Live mode only at launch, after the launch checklist.

## 7. Error handling

- Last seat race → second request gets 409 "This exam is fully booked".
- Deadline passed / exam not published → 409 with a clear message.
- Stripe unavailable when creating a session → hold released, 503 "Payments are temporarily unavailable".
- Webhook with bad signature → 400, nothing changes. Duplicate event → 200, nothing changes.
- Payment after hold expired and no seat → automatic full refund + admin flag.

## 8. Testing

- pgTAP: every rule above (seat limit under concurrency, deadline, teacher limits, RLS per role, attendance marking and closing, offline booking, cancellation transitions, money totals).
- Deno: create-booking (parent/student/forbidden cases, free exam), webhook (signature, duplicate, late payment with and without seat, refund events) using Stripe test mode and signed test payloads.
- Playwright (Stripe test mode): publish exam → parent books with test card → booking paid → admin sees money → request cancellation → admin partial refund; attendance by typed index number; index card renders.

## 9. Delivery

Built in stages, each reviewed: (1) venues + exams + timetable; (2) bookings + Stripe; (3) refunds + finance; (4) attendance + index cards; (5) staff home pages.
