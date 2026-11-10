# Stem Examspace Part 2 (Exams, bookings, attendance; Stripe last) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mock exams, bookings and attendance pages with real features: published exams, seat bookings (paid offline until the gateway stage), cancellations and manual refunds, money totals, QR attendance and index cards, real staff home pages, and finally Stripe Checkout.

**Architecture:** New Postgres tables with RLS; every write is a `security definer` SQL RPC that checks the caller's role/status itself (no gateway needed until Task 11), called from Next.js server actions with the user's session. Only Task 11 adds Edge Functions (Stripe needs secrets and a webhook).

**Tech Stack:** Supabase Postgres + pgTAP (`npm run db:test`), Deno Edge Functions (Task 11), Next.js 16.4 apps/web (server actions, Playwright e2e on port 3005), `qrcode` (npm) for index-card QR images, browser `BarcodeDetector` for scanning with typed fallback, Stripe Node/Deno SDK (Task 11 only).

**Spec:** `docs/superpowers/specs/2026-11-10-part2-exams-bookings-design.md` (read §9 first: payment gateway is the LAST stage). Part 1 spec and its decisions doc (`docs/superpowers/2026-11-10-part1-decisions-and-launch.md`) still bind.

## Global Constraints

- Every table has RLS on; default privileges are closed — every new table/function/view grants explicitly. Definer functions: `set search_path = ''`, fully-qualified names, actor read from `profiles` for `auth.uid()` with `status = 'active'`, row locks where state changes, audit row in the same transaction (ids only, no personal data).
- Migrations continue numbering after `20261110000028_*`; never edit an applied migration.
- Money: integer pence, currency `gbp`; display as £ with two decimals.
- Times: stored `timestamptz`; displayed in `Europe/London`.
- Booking statuses (until Task 11): `awaiting_payment`, `paid`, `cancel_requested`, `refunded`, `part_refunded`, `cancelled`, `expired`. Task 11 adds `reserved`.
- "Seats taken" = bookings in `awaiting_payment`, `paid`, `cancel_requested` (+ unexpired `reserved` after Task 11).
- One active booking per student per exam (partial unique index over the seat-taking statuses).
- Exam statuses: `draft`, `published`, `cancelled`, `completed`. Formats: `in_person`, `online`.
- Teachers: drafts only, own subjects (`teacher_subjects`), cannot set price or status. Owner/admin: everything.
- Attendance: present before `starts_at + interval '15 minutes'`, late after; only for students with a `paid` booking; closing the register (only after `starts_at`) marks the rest `absent` and sets the exam `completed`.
- Embeds between profiles and student_details use `student_details!profile_id(...)`.
- Tests run against the hosted dev project `jmhjahwfskhlgagaqlrz` serially; no persistent owner on dev; strict cleanup; never print keys. Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; work on `main`.

## Review Focus

1. **Two families taking the last seat at the same moment** → exactly one booking succeeds, the other gets "This exam is fully booked". Test: Task 3 `last_seat_race` (Deno, parallel RPC calls).
2. **Clock change / London time**: an exam at 09:00 London in BST and in GMT displays 09:00 and the 15-minute late rule uses the real instant. Test: Task 4 `late_threshold_uses_instant` and Task 6 display test for a summer and a winter date.
3. **Booking exactly at the deadline** → refused at and after `booking_deadline`, allowed one second before. Test: Task 3 `deadline_boundary`.
4. **Admin changes an exam's date after bookings exist** → bookings stay, families see the new date, audit row written; seat limit can't go below seats taken. Test: Task 2 `edit_published_keeps_bookings` and `seat_limit_not_below_taken`.
5. **Free exam (price 0)** → booking becomes `paid` immediately without admin action. Test: Task 3 `free_exam_paid_immediately`.

---

### Task 1: Schema, RLS and public timetable view

**Files:**
- Create: `supabase/migrations/20261110000029_exams_bookings_schema.sql`, `supabase/tests/014_exams_schema.test.sql`

**Interfaces:**
- Produces: enums `exam_format`, `exam_status`, `booking_status` (values per Global Constraints), `attendance_status ('present','late','absent')`; tables `venues(id uuid pk, name text unique not null, rooms text[] not null default '{}', active bool default true, created_at)`, `exams` (columns per spec §3 plus `updated_at`), `bookings` (spec §3; `stripe_*` columns nullable now; `paid_offline bool default false`; `refunded_pence int default 0`; `notes text`), `attendance(exam_id, student_id, status, marked_by, marked_at, pk(exam_id, student_id))`. Function `public.seats_taken(p_exam uuid) returns int` (definer, stable). View `public.exams_public` (published exams only: id, subject name, title, paper, format, venue name, room, starts_at, duration_minutes, price_pence, booking_deadline, seats_left) — granted to anon and authenticated; no personal data.
- RLS: exams — authenticated read published, staff read per role (owner/admin all, teacher own subjects incl. drafts); bookings and attendance — student own, parent linked children, tutor assigned students, teacher their subjects' exams, owner/admin all; venues — authenticated read, no client writes. No client INSERT/UPDATE/DELETE on any new table.

- [ ] **Step 1:** pgTAP: tables/enums exist with exact labels; checks (seat_limit > 0, price_pence ≥ 0, booking_deadline ≤ starts_at, online ⇒ venue null, in_person ⇒ venue not null); partial unique index blocks a second active booking; `exams_public` hides drafts and exposes no student data; RLS matrix per role (student/parent/tutor/teacher/admin/anon) with exact counts; clients cannot write any new table.
- [ ] **Step 2:** `npm run db:test` → FAIL. **Step 3:** write migration, `npm run db:push`. **Step 4:** → PASS (all files).
- [ ] **Step 5:** regenerate `packages/shared/src/database.types.ts` (`npx supabase gen types typescript --linked`), `npm test -w @stem/shared`, commit `feat(db): exams, venues, bookings, attendance schema`.

### Task 2: Exam and venue management RPCs

**Files:** Create `supabase/migrations/20261110000030_exam_management.sql`, `supabase/tests/015_exam_management.test.sql`

**Interfaces:**
- Produces (all definer, `grant execute … to authenticated`, return `jsonb` `{ ok, code?, id? }` with codes `forbidden|not_found|conflict|invalid_input`):
  - `save_venue(p_id uuid, p_name text, p_rooms text[], p_active bool)` — owner/admin.
  - `save_exam(p_id uuid, p_subject_id bigint, p_title text, p_paper text, p_format exam_format, p_venue_id uuid, p_room text, p_starts_at timestamptz, p_duration_minutes int, p_seat_limit int, p_price_pence int, p_booking_deadline timestamptz)` — create when p_id null. Teacher: only own subjects, only `draft` exams, `p_price_pence` ignored on create (0) and not changeable. Admin/owner: any; published exam edits allowed (audit `exam_updated`); price change refused (`conflict`) when any booking exists; `p_seat_limit < seats_taken` → `conflict`.
  - `set_exam_status(p_id uuid, p_status exam_status)` — owner/admin only; draft→published (requires price set explicitly ≥ 0 and future starts_at), published→cancelled (cancels `awaiting_payment` bookings; marks `paid`/`cancel_requested` as `cancel_requested` with note 'exam cancelled — refund due' for admin follow-up until Task 11), published→completed only via close register (Task 4).
- [ ] Tests: `teacher_cannot_save_other_subject`, `teacher_cannot_set_price_or_status`, `admin_publishes`, `edit_published_keeps_bookings` (date change keeps bookings + audit row), `seat_limit_not_below_taken`, `price_locked_after_booking`, `cancel_exam_flags_paid_for_refund`, privileges (anon cannot execute).
- [ ] FAIL → implement → push → PASS → commit `feat(db): exam and venue management`.

### Task 3: Booking RPCs (no gateway) and expiry

**Files:** Create `supabase/migrations/20261110000031_bookings.sql`, `supabase/tests/016_bookings.test.sql`, `supabase/functions/_shared/bookings_race.test.ts` (Deno, for the race only)

**Interfaces:**
- Produces:
  - `create_booking(p_exam uuid, p_student uuid) returns jsonb` — caller active student (p_student = self) or active parent linked to p_student; student must be `active`; lock exam row; checks published, `now() < booking_deadline`, seats_taken < seat_limit, no active booking; inserts `awaiting_payment` (or `paid` when price_pence = 0) with `amount_pence = price_pence`, `booked_by = auth.uid()`; audit `booking_created`. Codes: `fully_booked`, `deadline_passed`, `not_bookable`, `already_booked`, `forbidden`.
  - `admin_add_booking(p_exam uuid, p_student uuid, p_paid bool, p_note text)` — owner/admin; same seat/state checks (deadline ignored), `paid_offline = p_paid`.
  - `mark_booking_paid(p_booking uuid, p_note text)` — owner/admin; `awaiting_payment` → `paid`, `paid_offline = true`.
  - `cancel_booking_admin(p_booking uuid, p_note text)` — owner/admin; `awaiting_payment` → `cancelled`.
  - `request_cancellation(p_booking uuid)` — booking's student or a linked parent; `paid` → `cancel_requested`; only before `starts_at`.
  - `decide_cancellation(p_booking uuid, p_approve bool, p_refund_pence int, p_note text)` — owner/admin; approve: `refunded` if refund = amount, `part_refunded` if 0 < refund < amount, `cancelled` if 0; seat released; decline → `paid`. Refund is recorded only (no gateway) — `refunded_pence`.
  - `expire_unpaid_bookings() returns int` — `awaiting_payment` with exam `booking_deadline < now()` → `expired`; pg_cron every 5 minutes (`expire-unpaid-bookings`).
- [ ] Tests (pgTAP): `student_books_self`, `parent_books_linked_child`, `parent_cannot_book_unlinked`, `pending_student_cannot_be_booked`, `deadline_boundary` (now = deadline − 1s ok; = deadline refused — make functions take an optional `p_now timestamptz default now()` only on internal helpers, not on the client RPC; test via a SQL helper), `fully_booked`, `already_booked`, `free_exam_paid_immediately`, `admin_marks_paid`, `request_and_partial_refund`, `decline_returns_to_paid`, `expiry_releases_seat`, cron job exists. Deno `last_seat_race`: seat_limit 1, two students' sessions call `create_booking` in parallel → exactly one `ok`, other `fully_booked`.
- [ ] FAIL → implement → push → PASS → commit `feat(db): bookings without payment gateway`.

### Task 4: Attendance RPCs and index card data

**Files:** Create `supabase/migrations/20261110000032_attendance.sql`, `supabase/tests/017_attendance.test.sql`

**Interfaces:**
- Produces:
  - `attendance_lookup(p_exam uuid, p_index text) returns jsonb` — owner/admin or teacher of the exam's subject; normalises the index like `packages/shared/src/index-number.ts` (port the same rules to SQL `normalise_index(text)`); returns `{ ok, studentId, name, photoPath, booked: bool, status }` or `not_found` (no other data).
  - `mark_attendance(p_exam uuid, p_student uuid) returns jsonb` — same callers; requires a `paid` booking; status `present` if `now() < starts_at + 15 min` else `late`; idempotent (re-scan keeps first mark); audit.
  - `close_register(p_exam uuid) returns jsonb` — owner/admin or subject teacher; only if `now() >= starts_at`; unmarked paid students → `absent`; exam → `completed`.
- [ ] Tests: `teacher_other_subject_forbidden`, `unbooked_student_refused`, `late_threshold_uses_instant` (exam starts_at set as `'2026-07-01 09:00 Europe/London'` and `'2026-12-01 09:00 Europe/London'`, marks at +14 and +16 minutes via internal helper with p_now), `rescan_idempotent`, `close_marks_absent_and_completes`, `close_before_start_refused`, lookup returns nothing for unknown index.
- [ ] FAIL → implement → push → PASS → commit `feat(db): attendance`.

### Task 5: Public timetable and family booking pages

**Files:** Modify `apps/web/src/app/exams/page.tsx`; create `apps/web/src/app/exams/[id]/book/page.tsx` + `actions.ts`, `apps/web/src/app/account/bookings/page.tsx`, `apps/web/src/components/bookings/*`, `apps/web/src/lib/money.ts` (`formatPence(p: number): string`, `formatLondon(ts: string): string`), e2e `apps/web/e2e/bookings-family.spec.ts`

**Interfaces:**
- Consumes: `exams_public`, `create_booking`, `request_cancellation`, bookings RLS reads.
- Produces: `/exams` (public, subject filter, seats left, "Book"); `/exams/[id]/book` (signed-in; parent chooses linked child; shows price and "You will pay the institution directly — your booking is held until the booking deadline" until Task 11); `/account/bookings` linked from the account pages ("My bookings": upcoming/past, status labels, "Request cancellation").
- [ ] Tests (Playwright): public page shows a published exam with London-time display for a summer and a winter date and hides drafts; parent books for child → appears in My bookings as "Awaiting payment"; student books self; fully booked shows message; request cancellation on a paid booking. Unit tests for `formatPence`/`formatLondon`.
- [ ] FAIL → implement → PASS (plus tsc, lint, build) → commit `feat(web): timetable and family bookings`.

### Task 6: Staff exam and venue pages

**Files:** Replace mock `apps/web/src/app/admin/exams/page.tsx` (+ `actions.ts`, components); create `apps/web/src/app/admin/venues/page.tsx`, `apps/web/src/app/teacher/exams/page.tsx`; update `AppShell` navs; e2e `apps/web/e2e/staff-exams.spec.ts`

**Interfaces:**
- Consumes: Task 2 RPCs, `requireStaff`.
- [ ] Tests: admin creates in-person exam (venue+room) and online exam, publishes, edits date; teacher sees only own subjects, creates draft, cannot see price/publish controls; admin cannot lower seat limit below bookings (message shown); cancel exam shows bookings flagged for refund. Remove the "Preview — sample data" banner from these pages.
- [ ] FAIL → implement → PASS → commit `feat(web): staff exams and venues`.

### Task 7: Admin bookings and finance

**Files:** Replace mock `apps/web/src/app/admin/bookings/page.tsx` (+ actions, components); create `apps/web/src/app/admin/finance/page.tsx`, SQL view or RPC `money_totals(p_from date, p_to date)` in `supabase/migrations/20261110000033_finance.sql` (owner/admin; per exam and per month: paid amount − refunded) + pgTAP `018_finance.test.sql`; e2e `apps/web/e2e/admin-bookings.spec.ts`

- [ ] Tests: filters (status, exam, search); add offline booking; mark paid; approve cancellation with partial refund (amounts shown); decline; finance totals match seeded bookings exactly (pgTAP + UI); teacher/tutor cannot open finance.
- [ ] FAIL → implement → PASS → commit `feat(web): bookings admin and finance`.

### Task 8: Attendance page, QR scanning and index cards

**Files:** Replace mock `apps/web/src/app/admin/attendance/page.tsx`; create `apps/web/src/app/admin/attendance/[examId]/page.tsx` (+ actions), `apps/web/src/components/attendance/Scanner.tsx` (BarcodeDetector when available, camera via getUserMedia; otherwise typed input only), `apps/web/src/app/cards/[studentId]/page.tsx` (printable A6 card: name, index number, QR of the index number only via `qrcode`, photo via signed URL) accessible to owner/admin and to the student themself; e2e `apps/web/e2e/attendance.spec.ts`
- [ ] Tests: typed index marks present and shows photo/name; unknown index shows "Not found"; unbooked student shows "No paid booking"; close register → absent list; card page renders QR whose decoded text equals the index number (decode in test with a QR library) and contains no other personal data in the QR; another student cannot open someone else's card.
- [ ] FAIL → implement → PASS → commit `feat(web): attendance and index cards`.

### Task 9: Staff home pages

**Files:** Modify `apps/web/src/app/{teacher,tutor,corrector}/page.tsx`; e2e `apps/web/e2e/staff-homes.spec.ts`
- [ ] Teacher home: own upcoming exams with seats booked and draft count; tutor home: assigned students' upcoming bookings; corrector home: "Marking arrives in the next update" (Part 3). Tests per role with exact counts.
- [ ] FAIL → implement → PASS → commit `feat(web): staff home pages`.

### Task 10: Part 2 (pre-gateway) wrap-up

- [ ] Update `docs/superpowers/2026-11-10-part1-decisions-and-launch.md` launch checklist with Part 2 items (cron jobs exist on live; Stripe pending). Run the whole suite (db, Deno, shared, Playwright serial, tsc, lint, build). Commit `docs: Part 2 status`.

### Task 11: Stripe Checkout (LAST — needs owner's Stripe test keys)

**Blocked until:** owner sets Edge Function secrets `STRIPE_SECRET_KEY` (test) and `STRIPE_WEBHOOK_SECRET` and creates the webhook endpoint (spec §6). Claude never handles these values.

**Files:** migration `..._stripe.sql` (add `reserved` status, `hold_expires_at`, `stripe_events`, expiry of holds every 5 min), `supabase/functions/create-booking/`, `supabase/functions/stripe-webhook/`, shared helper `createCheckout`, web booking page switches to "Book and pay" when price > 0, `/bookings/success`, `/bookings/cancelled`, admin refund via Stripe Refunds API, automatic refunds on exam cancellation; tests per spec §8 (signature, duplicate event, late payment with/without seat, refund events, Playwright with test card `4242 4242 4242 4242`).
- [ ] Implement per spec §4 Stripe rules; FAIL → PASS → commit `feat: Stripe Checkout payments`.
