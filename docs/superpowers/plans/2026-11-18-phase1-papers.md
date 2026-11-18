# Phase 1A: Home and centre sittings with personalised papers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Families choose a home or centre sitting (and a centre, when an exam has several); admins upload the question paper once; each candidate gets a personalised PDF with identity bands and a QR code on every page, released at a set time; staff print one pack per centre; a scan check reads printed codes back.

**Architecture:** Postgres (Supabase) holds sittings, centres, paper versions, copy records and the download log, with every permission and release rule in `security definer` SQL functions. An Edge Function `paper-copy` builds one candidate's copy with pdf-lib (checks and logging through those SQL functions); `paper-register` validates uploaded papers. The Next.js web app has no service-role key: it uploads papers straight to private storage as an admin, downloads copies from `paper-copy`, merges print packs in the admin's browser, and reads QR codes in the browser for the scan check.

**Tech Stack:** Supabase (Postgres 17, pg_cron, pg_net, Storage, Edge Functions on Deno), pgTAP, Next.js 16 (App Router, server actions), React 19, pdf-lib 1.17.1, qrcode 1.5.4, jsQR 1.4.0, pdfjs-dist 4, Vitest, Playwright.

**Spec:** `docs/superpowers/specs/2026-11-17-phase1-papers-design.md` (approved 2026-11-18). Master plan: `docs/owner/2026-11-functional-specification.pdf`, sections 8 to 10.

## Global Constraints

- Row-level security on every new table; writes only through `security definer` SQL functions with `set search_path = ''` or Edge Functions; `revoke execute ... from public, anon` then explicit grants; an `audit_log` row in the same transaction as every staff change; no personal data in logs or error messages.
- The web app never holds the service-role key. Only Edge Functions use it.
- Every test runs against the local database (Docker), never the live project `jmhjahwfskhlgagaqlrz`. Never run `db:push`, `fn:deploy` or `vercel deploy` while executing this plan.
- Work on branch `phase1-papers`, one commit per task, messages ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Sitting wording in every screen: "At the centre", "At home", "At the centre or at home". Enum values stay `in_person` (centre only), `online` (home only), and the new `both`.
- Times are stored as `timestamptz` and shown in `Europe/London`.
- Release time = start minus `release_minutes_before` (default 10, allowed 0 to 120), unless released early. Home copies can be downloaded until the scheduled end plus 2 hours.
- Spare answer pages per copy: default 2, allowed 0 to 6. Paper PDFs at most 40 MB.
- QR content is exactly `SX1.<code>.<page>`: `<code>` is the copy code (8 random Crockford base32 characters, 40 bits, plus 1 check character), `<page>` is the 1-based page number including spare pages. No name, index number or booking id in the QR.
- Copy codes are unique across all exams and never reused.
- A candidate can make at most 20 home downloads per hour.
- Bookings that hold a seat or get a paper: statuses `paid` and `cancel_requested` (plus `awaiting_payment` for seat counting only, as today).
- Family copy (exact text): before release "Your paper will be ready at {time} on {day date}"; held "The paper is paused by the institution. Please wait."; centre "Your booking is for the centre; your paper is handed out in the exam room"; missing "Your paper is not ready yet. The institution has been told."; failure "The paper could not be prepared. Please try again."; corrected "A corrected paper is available. Download it again."; after download "Downloaded at {time} by {name}".

## Review Focus

1. Two families book the last seat at centre A while centre B has seats: exactly one gets centre A, the other is told centre A is full and can choose B. Test: Task 2 `last_seat_race_per_centre`.
2. An exam is moved to a new date after its paper is uploaded: the release time moves with it. Test: Task 5 `release_follows_reschedule`.
3. A family downloaded version 1, then the paper is replaced: their booking shows the corrected-paper message, and codes from version 1 still look up in the scan check. Tests: Task 5 `replaced_paper_new_copy_old_code_still_found`, Task 9 `booking_paper_state_reports_corrected`.
4. A device clock is wrong: only the database clock decides release. Test: Task 5 `release_boundary_uses_server_time` (09:49:59 refused, 09:50:00 allowed via `p_now`).
5. A booking is cancelled after its copy was downloaded: no more downloads, but its codes still look up. Test: Task 5 `cancelled_booking_keeps_copy_but_cannot_download`.

## File map

| Area | Files |
|---|---|
| Local test setup | `scripts/db-test.mjs`, `package.json`, `.gitignore`, `supabase/functions/.env.test.local` (git-ignored, generated) |
| Sittings and centres (DB) | `supabase/migrations/20261118000045_exam_format_both.sql`, `..000046_exam_centres.sql`, `..000047_bookings_sittings.sql`, `supabase/tests/014`–`021` (updated), `supabase/tests/023_exam_centres.test.sql`, `supabase/tests/024_booking_sittings.test.sql`, `supabase/functions/_shared/bookings_race.test.ts` |
| Sittings and centres (web) | `apps/web/src/lib/exam-form.ts`, `exam-rpc.ts`, `exams-staff.ts`, `staff-homes.ts`, `attendance.ts`, `home-exams.ts`, `home-demo.ts`, `bookings-admin.ts`, `components/exams/ExamForm.tsx`, `ExamsManager.tsx`, `TeacherExams.tsx`, `components/attendance/*`, `components/home/PaperFinder.tsx`, `components/bookings/AdminBookingsManager.tsx`, `app/exams/page.tsx`, `app/exams/[id]/book/*`, `app/account/bookings/*`, `app/admin/attendance/*`, `app/teacher/attendance/*`, `app/teacher/page.tsx`, `packages/shared/src/errors.ts`, `packages/shared/src/database.types.ts` |
| Papers (DB) | `supabase/migrations/20261118000048_exam_papers.sql`, `supabase/tests/025_exam_papers.test.sql` |
| Papers (Edge) | `supabase/functions/_shared/paper/stamp.ts`, `stamp.test.ts`, `supabase/functions/paper-register/index.ts` (+ `index.test.ts`), `supabase/functions/paper-copy/index.ts` (+ `index.test.ts`), `supabase/functions/deno.json`, `supabase/config.toml`, `packages/shared/src/functions.ts` |
| Papers (web) | `apps/web/src/app/admin/exams/[id]/page.tsx` (+ `actions.ts`), `components/papers/*`, `lib/print-pack.ts` (+ test), `lib/paper-payload.ts` (+ test), `lib/paper-state.ts`, `app/admin/exams/scan-check/page.tsx` |
| Release email | `supabase/migrations/20261118000049_paper_release_notify.sql`, `supabase/functions/paper-release-notify/index.ts` (+ test), `supabase/functions/_shared/email.ts` |

---

### Task 0: Local test database

**Files:**
- Modify: `scripts/db-test.mjs`, `package.json`, `.gitignore`, `apps/web/e2e/admin.ts`, `apps/web/playwright.config.ts`, `apps/web/package.json`

**Interfaces:**
- Produces: `npm run db:test:local`, `npm run fn:test:local` and `npm run e2e:local -w @stem/web`, used by every later task. Today the browser tests and function tests read `.env.dev.local`, which points at the live project; after this task the local commands never touch it.

- [ ] **Step 1: Ask the owner to open Docker Desktop**, then run `npx supabase start` and `npx supabase db reset`. Expected: all migrations up to `20261115000044` apply with no error.
- [ ] **Step 2: Local mode in `scripts/db-test.mjs`.** With a `--local` argument, call `npx supabase db query -f <file>` (local is the CLI default) instead of `--remote --yes`. Keep the commit guard. Add `"db:test:local": "node scripts/db-test.mjs --local"`.
- [ ] **Step 3: Test env file.** Generate `supabase/functions/.env.test.local` from `npx supabase status -o env` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, plus `EMAIL_PROVIDER=console`, `SITE_URL=http://localhost:3005`). Add it to `.gitignore`. Add `"fn:test:local"` = the `fn:test` command with `--env-file=supabase/functions/.env.test.local`.
- [ ] **Step 4: Browser tests on the local stack.** `e2e/admin.ts` reads the env file named by `E2E_ENV_FILE` (default `.env.dev.local`, unchanged). `playwright.config.ts` passes `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` from that same file to `webServer.env` (process env wins over `apps/web/.env.local`). Add `"e2e:local": "cross-env E2E_ENV_FILE=supabase/functions/.env.test.local playwright test"` in `apps/web/package.json` (use `node --env-file` or a small wrapper if `cross-env` is not installed; do not add a dependency for this alone).
- [ ] **Step 5: Baseline.** Run `npm run db:test:local`, `npm run fn:test:local` (with `npx supabase functions serve --env-file supabase/functions/.env.test.local` in the background) and `npm run e2e:local -w @stem/web`. Expected: every existing suite passes. Record any pre-existing failure in the commit message rather than fixing it here.
- [ ] **Step 5: Commit** `chore: run database and function tests against a local Supabase`.

### Task 1: Exam centres (database)

**Files:**
- Create: `supabase/migrations/20261118000045_exam_format_both.sql`, `supabase/migrations/20261118000046_exam_centres.sql`, `supabase/tests/023_exam_centres.test.sql`
- Modify: `supabase/tests/014_exams_schema.test.sql`, `015_exam_management.test.sql`, and the `mk_exam` helpers in `016`–`021`

**Interfaces:**
- Produces:
  - enum `exam_format` gains `'both'` (own migration: a new enum value cannot be used in the transaction that adds it).
  - table `public.exam_centres(id uuid pk default gen_random_uuid(), exam_id uuid not null references exams on delete cascade, venue_id uuid not null references venues, room text not null, seat_limit int not null check (seat_limit between 1 and 1000), register_closed_at timestamptz, created_at timestamptz not null default now(), unique (exam_id, venue_id, room))`.
  - `exams.venue_id`, `exams.room`, `exams.seat_limit`, the checks `exams_venue_matches_format` and `exams_online_has_no_room` are dropped after backfill. Each `in_person` exam gets one centre from its old venue, room and seat limit.
  - `public.centre_seats_taken(p_centre uuid) returns int` (counts `awaiting_payment`, `paid`, `cancel_requested` bookings at that centre while the exam is not cancelled; execute for `service_role` only). `public.seats_taken(uuid)` is dropped.
  - `public.save_exam(p_id uuid, p_subject_id bigint, p_title text, p_paper text, p_format exam_format, p_centres jsonb, p_starts_at timestamptz, p_duration_minutes int, p_price_pence int, p_booking_deadline timestamptz) returns jsonb`. The old 12-argument version is dropped. `p_centres` is an array of `{"id"?: uuid, "venue_id": uuid, "room": text, "seat_limit": int}`.
  - `public.exams_public` recreated with columns `id, subject, title, paper, format, starts_at, duration_minutes, price_pence, booking_deadline, seats_left, centres`. `seats_left` is the sum over centres (null when `format = 'online'`). `centres` is a jsonb array `[{id, venue, seats_left}]` ordered by venue name; rooms are not exposed. Keep `security_barrier` and the existing grants.
  - `exam_centres` RLS select mirrors `exams_select` and `exams_select_family` (visible when its exam is visible to the caller).

- [ ] **Step 1: Update the pinned tests to the new shape** in `014` and `015` (and the `mk_exam` helpers in `016`–`021`: insert the exam, then one `exam_centres` row when the format is `in_person`). Replace the old venue/room/seat-limit assertions with the new ones below rather than deleting their intent.
- [ ] **Step 2: Write `023_exam_centres.test.sql`** with at least:
  - `backfill_one_centre_per_in_person_exam`: an exam created before the migration keeps its venue, room and seat limit as one centre.
  - `save_exam_two_centres`: `in_person` with two centres saves both; the view shows `seats_left` = sum and two entries in `centres`.
  - `online_exam_has_no_centres`: `online` with a non-empty `p_centres` returns `invalid_input`; `in_person` or `both` with an empty array returns `invalid_input`.
  - `duplicate_centre_refused`: the same venue and room twice returns `invalid_input`.
  - `centre_seat_limit_not_below_taken`: lowering one centre below its taken seats returns `conflict`.
  - `centre_with_bookings_cannot_be_removed`: leaving out a centre that has live bookings returns `conflict`.
  - `format_switch_refused_with_conflicting_bookings`: `both` to `online` with live centre bookings, and `both` to `in_person` with live home bookings, both return `conflict`.
  - `publish_checks_every_centre`: publishing with an inactive venue or a room no longer in the venue returns `invalid_input`.
  - `save_venue_protects_centres`: deactivating a venue, or removing a room, used by an upcoming exam centre is refused.
  - `view_hides_rooms`: `exams_public.centres` entries have no `room` key.
- [ ] **Step 3: Run** `npm run db:test:local`. Expected: `023` fails (function signature not found), updated `014`/`015` fail.
- [ ] **Step 4: Write the two migrations.** Port `save_exam` (latest in `20261110000043`), `set_exam_status` (latest in `20261110000035`) and `save_venue` (latest in `20261110000033`) to centres, keeping every existing rule (teacher limits, price rules, frozen dates after start, audit rows). Inside `save_exam`, lock each existing centre `for update` before comparing seat limits.
- [ ] **Step 5: Run** `npx supabase db reset && npm run db:test:local`. Expected: all suites pass.
- [ ] **Step 6: Regenerate types** `npx supabase gen types typescript --local > packages/shared/src/database.types.ts`.
- [ ] **Step 7: Commit** `feat(db): exams run at one or more centres`.

### Task 2: Booking sittings and per-centre registers (database)

**Files:**
- Create: `supabase/migrations/20261118000047_bookings_sittings.sql`, `supabase/tests/024_booking_sittings.test.sql`
- Modify: `supabase/tests/016_bookings.test.sql`, `018_attendance.test.sql`, `supabase/functions/_shared/bookings_race.test.ts`

**Interfaces:**
- Consumes: `exam_centres`, `centre_seats_taken` (Task 1).
- Produces:
  - enum `public.sitting_mode ('centre', 'home')`; `bookings.sitting sitting_mode not null`, `bookings.centre_id uuid references exam_centres`, check `(sitting = 'centre') = (centre_id is not null)`. Backfill: bookings on `in_person` exams become `centre` at the exam's single centre; on `online` exams, `home`.
  - `booking_create_core(p_exam, p_student, p_by, p_now, p_enforce_deadline, p_paid, p_note, p_sitting sitting_mode, p_centre uuid) returns jsonb`: after locking the exam, resolve the sitting (null and the exam offers one sitting: use it; null and `both`: `choose_sitting`; not offered: `sitting_not_offered`), resolve the centre (null and one centre: use it; null and several: `choose_centre`; not this exam's: `invalid_input`), lock the centre row `for update`, refuse with `centre_full` when `centre_seats_taken >= seat_limit`. Home sittings have no limit. Insert `sitting` and `centre_id`.
  - `booking_create_as(p_actor, p_exam, p_student, p_now, p_sitting sitting_mode default null, p_centre uuid default null)`, `create_booking(p_exam, p_student, p_sitting sitting_mode default null, p_centre uuid default null)`, `admin_add_booking(p_exam, p_student, p_paid, p_note, p_sitting sitting_mode default null, p_centre uuid default null)`. Drop the old signatures; keep grants as today.
  - `public.change_booking_sitting(p_booking uuid, p_sitting sitting_mode, p_centre uuid, p_reason text) returns jsonb`: owner/admin only, live bookings only, reason 1 to 300 characters, seat check at the target centre, audit action `booking_sitting_changed`.
  - Registers per centre: `attendance_lookup(p_centre uuid, p_index text)`, `mark_attendance(p_centre uuid, p_student uuid)`, `close_register(p_centre uuid)` and their `_as` variants take a centre instead of an exam. Only `sitting = 'centre'` bookings at that centre are on the register. `close_register` sets `exam_centres.register_closed_at` and marks only that centre's unscanned candidates absent; audit target type `exam_centre`. Error codes and other rules unchanged.

- [ ] **Step 1: Write `024_booking_sittings.test.sql`** with at least: `single_sitting_exam_needs_no_choice`, `both_without_sitting_is_choose_sitting`, `several_centres_without_centre_is_choose_centre`, `centre_from_other_exam_refused`, `centre_full_but_other_centre_free` (fill centre A, book centre B succeeds, centre A returns `centre_full`), `home_has_no_limit` (11 home bookings on an exam whose only centre has 10 seats), `change_booking_sitting_checks_seats_and_audits`, `family_cannot_change_sitting`, `register_lists_only_that_centre`, `close_register_marks_only_that_centre_absent`, `home_candidate_not_on_any_register`.
- [ ] **Step 2: Update `bookings_race.test.ts`:** rename the race test to `last_seat_race_per_centre`. Two centres with one seat each; two students race for centre A: exactly one succeeds and the other gets `centre_full`; a third books centre B successfully.
- [ ] **Step 3: Run** `npm run db:test:local` and `npm run fn:test:local`. Expected: new tests fail.
- [ ] **Step 4: Write the migration**, porting the latest `booking_create_core` (`20261110000035`), `booking_create_as` and `admin_add_booking` (`20261110000036`) and the attendance functions (`20261110000037`, `..039`, `..043`). Update `016`/`018` callers to the new signatures.
- [ ] **Step 5: Run** both test commands. Expected: all pass.
- [ ] **Step 6: Regenerate types** (as in Task 1).
- [ ] **Step 7: Commit** `feat(db): bookings record home or centre sitting; registers per centre`.

### Task 3: Sittings and centres for staff (web)

**Files:**
- Modify: `apps/web/src/lib/exam-form.ts` (+ `exam-form.test.ts`), `lib/exam-rpc.ts`, `lib/exams-staff.ts`, `lib/staff-homes.ts`, `lib/attendance.ts`, `components/exams/ExamForm.tsx`, `ExamsManager.tsx`, `TeacherExams.tsx`, `components/attendance/Views.tsx`, `components/attendance/actions.ts`, `app/admin/attendance/[examId]/page.tsx`, `app/teacher/attendance/[examId]/page.tsx`, `app/teacher/page.tsx`, `packages/shared/src/errors.ts`, `apps/web/e2e/staff-exams.spec.ts`, `staff-homes.spec.ts`, `attendance.spec.ts`

**Interfaces:**
- Consumes: `save_exam` with `p_centres`; per-centre attendance functions (Tasks 1–2).
- Produces:
  - `type ExamFormat = "in_person" | "online" | "both"`; `type CentreValues = { id?: string; venueId: string; room: string; seatLimit: number }`; `ExamValues` replaces `venueId`, `room` and `seatLimit` with `centres: CentreValues[]`.
  - `parseExamForm(raw, { withPrice })` reads centres from fields `centre.<i>.venue`, `centre.<i>.room`, `centre.<i>.seats`, `centre.<i>.id`.
  - `SITTING_LABEL: Record<ExamFormat, string>` (`in_person` "At the centre", `online` "At home", `both` "At the centre or at home") and `SITTING_MODE_LABEL: Record<"centre" | "home", string>` ("At the centre", "At home") in `apps/web/src/lib/exam-form.ts`; used by every screen in Tasks 3, 4 and 9.
  - `ExamRow.centres: { id: string; venueId: string; venue: string; room: string; seatLimit: number; seatsSold: number }[]`.
  - Register routes take `?centre=<id>`. With one centre it is chosen automatically; with several, the page asks first.

- [ ] **Step 1: Write failing vitest cases** in `exam-form.test.ts`: `online_exam_drops_centres`, `in_person_needs_at_least_one_centre`, `both_keeps_two_centres`, `rejects_duplicate_centre`, `rejects_centre_seats_out_of_range` (0 and 1001).
- [ ] **Step 2: Run** `npm test -w @stem/web -- exam-form`. Expected: FAIL.
- [ ] **Step 3: Implement** the form parsing, `callSaveExam` (`p_centres`), `explainSaveConflict` per centre, the centres editor in `ExamForm` (add and remove rows; hidden for `online`), list and teacher views showing each centre and "x of y seats" per centre, and the register's centre chooser. Add messages to `packages/shared/src/errors.ts` for `choose_sitting`, `choose_centre`, `centre_full` and `sitting_not_offered`, and update the venue/room wording in `examMessageFor`.
- [ ] **Step 4: Run** `npm test -w @stem/web`, `npx tsc --noEmit -p apps/web`, `npx eslint apps/web/src`. Expected: pass.
- [ ] **Step 5: Update the three e2e specs** (seeds write `exam_centres`; `admin_creates_exam_at_two_centres` replaces `admin_creates_in_person_exam…`) and run them locally against the local stack. Expected: pass.
- [ ] **Step 6: Commit** `feat(web): staff set up exams at one or more centres`.

### Task 4: Sittings and centres for families (web)

**Files:**
- Modify: `apps/web/src/lib/home-exams.ts` (+ test), `lib/home-demo.ts`, `components/home/PaperFinder.tsx`, `app/exams/page.tsx`, `app/exams/[id]/book/page.tsx`, `app/exams/[id]/book/actions.ts`, the book form component, `app/account/bookings/page.tsx`, `lib/bookings-admin.ts`, `components/bookings/AdminBookingsManager.tsx`, `app/admin/bookings/actions.ts`, `apps/web/e2e/bookings-family.spec.ts`, `admin-bookings.spec.ts`

**Interfaces:**
- Consumes: `exams_public.centres` and `seats_left` (Task 1), `create_booking(p_exam, p_student, p_sitting, p_centre)` and `change_booking_sitting` (Task 2), `SITTING_LABEL` (Task 3).
- Produces: `PublicExam.centres: { id: string; venue: string; seats_left: number }[]`; `placeText(exam)` returns `SITTING_LABEL` plus the venue names; `bookExam(examId, studentId, sitting, centreId)`; `changeSittingAction(bookingId, sitting, centreId, reason)`.

- [ ] **Step 1: Failing tests** in `home-exams.test.ts`: `place_text_for_home_only`, `place_text_lists_centres`, `seats_left_null_for_home_only_shows_no_seat_line`.
- [ ] **Step 2: Run** and confirm FAIL.
- [ ] **Step 3: Implement.** The booking screen asks "Where will they sit it?" (radio: At the centre / At home) only when the exam is `both`, then "Which centre?" (radio list with seats left; full centres disabled) only when there are several. My bookings shows the sitting and centre. The admin bookings list shows them and adds **Change sitting** (sitting, centre, reason).
- [ ] **Step 4: Run** unit tests, typecheck, lint and the two e2e specs (add `family_books_home_sitting` and `family_picks_a_centre`). Expected: pass.
- [ ] **Step 5: Commit** `feat(web): families choose home or centre and which centre`.

### Task 5: Papers, copies and release (database)

**Files:**
- Create: `supabase/migrations/20261118000048_exam_papers.sql`, `supabase/tests/025_exam_papers.test.sql`

**Interfaces:**
- Consumes: `bookings.sitting` and `centre_id` (Task 2).
- Produces:
  - `exams` gains `exam_code text unique not null` (generated on insert by a trigger as `<SUBJECT>-<PAPER initials>-<YYYY>-<MM>`, upper case, with `-2`, `-3` appended on collision; backfilled), `release_minutes_before int not null default 10 check (between 0 and 120)`, `spare_pages int not null default 2 check (between 0 and 6)`, `release_held boolean not null default false`, `released_early_at timestamptz`, `release_notified_at timestamptz`.
  - enum `paper_kind ('paper', 'insert')`; table `exam_papers(id uuid pk, exam_id, kind, title text not null, version int not null, storage_path text unique not null, page_count int not null check (> 0), byte_size bigint not null, uploaded_by uuid, uploaded_at timestamptz not null default now(), replace_reason text, superseded_at timestamptz, corrected_notified_at timestamptz)`. The current paper is the `kind = 'paper'` row with `superseded_at is null` (at most one per exam: partial unique index).
  - table `paper_copies(id uuid pk, code text unique not null, booking_id uuid not null references bookings, paper_id uuid not null references exam_papers, page_count int not null, created_at timestamptz not null default now(), unique (booking_id, paper_id))`.
  - enum `paper_download_kind ('home', 'print_pack', 'reprint', 'admin_preview')`; table `paper_downloads(id bigint identity pk, copy_id uuid not null references paper_copies, downloaded_by uuid, kind paper_download_kind not null, at timestamptz not null default now())`.
  - Storage bucket `exam-papers` (private, 41943040 bytes, `application/pdf`), objects at `<exam_id>/<uuid>.pdf`; insert, select and delete for `is_staff_admin()` only.
  - `copy_code_new() returns text` and `copy_code_valid(p_code text) returns boolean` (Crockford base32 without I, L, O, U; the check character is the mod-37 Crockford check symbol over the 8 data characters).
  - `paper_release_at(p_exam uuid) returns timestamptz` = `coalesce(released_early_at, starts_at - release_minutes_before * interval '1 minute')`.
  - `set_exam_paper_settings(p_exam uuid, p_exam_code text, p_release_minutes_before int, p_spare_pages int) returns jsonb` (admin; exam code `^[A-Z0-9-]{3,40}$`, refused with `conflict` once any copy exists; audit `exam_paper_settings_changed`).
  - `register_exam_paper(p_exam uuid, p_kind paper_kind, p_title text, p_storage_path text, p_page_count int, p_byte_size bigint, p_reason text) returns jsonb` (admin; a new `paper` supersedes the previous one; a reason of 3 to 300 characters is required when any copy of the previous paper exists; audit `paper_uploaded` or `paper_replaced`).
  - `remove_exam_insert(p_paper uuid, p_reason text) returns jsonb` (admin; sets `superseded_at`; audit).
  - `paper_release_now(p_exam uuid, p_reason text)`, `paper_hold(p_exam uuid, p_reason text)`, `paper_resume(p_exam uuid, p_reason text)`, all `returns jsonb`, admin, audited.
  - `paper_copy_issue(p_booking uuid, p_kind paper_download_kind, p_now timestamptz default now()) returns jsonb`: decides, creates or reuses the copy for the current paper, and returns `{ok, copy_id, code, page_count, spare_pages, storage_path, paper_version, candidate_name, index_number, exam_code, exam_title, starts_at, differs_from_previous}` or `{ok: false, code}` with codes `forbidden`, `not_found`, `paper_missing`, `paper_held`, `paper_not_released`, `paper_closed`, `wrong_sitting`, `rate_limited`. Rules: `home` for the active student or an active linked parent, a `paid` or `cancel_requested` home booking, not held, between release and end plus 2 hours, at most 20 `home` downloads per booking in the last hour; `print_pack` and `reprint` for owner/admin on `paid` or `cancel_requested` centre bookings; `admin_preview` for owner/admin on any booking. Execute for `authenticated` (and `service_role` for tests).
  - `paper_download_log(p_copy uuid, p_kind paper_download_kind) returns jsonb` (same permission as the issue; inserts one `paper_downloads` row).
  - `paper_insert_issue(p_booking uuid, p_insert uuid, p_now timestamptz default now()) returns jsonb` (same release rules as `home`, or admin) returning `{ok, storage_path, title}`.
  - `booking_paper_state(p_booking uuid, p_now timestamptz default now()) returns jsonb` (family or admin): `{sitting, status: 'centre' | 'missing' | 'not_yet' | 'held' | 'open' | 'closed', release_at, last_download: {at, by_name} | null, corrected: boolean, inserts: [{id, title}]}`.
  - `paper_lookup_codes(p_items jsonb) returns jsonb` (admin): input `[{code, page}]`, output `[{code, page, found, exam_code, exam_title, index_number, page_count, paper_version, current}]`.
  - RLS on the three new tables: select for `is_staff_admin()` only; no direct writes.

- [ ] **Step 1: Write `025_exam_papers.test.sql`** with at least:
  - `release_boundary_uses_server_time` (start 10:00, `p_now` 09:49:59 gives `paper_not_released`, 09:50:00 succeeds);
  - `release_follows_reschedule` (moving `starts_at` moves `paper_release_at`);
  - `release_now_and_hold_are_audited` (held gives `paper_held`, resume restores; three audit rows);
  - `closed_two_hours_after_end`;
  - `linked_parent_allowed_other_parent_refused`;
  - `centre_booking_gets_wrong_sitting_for_home`;
  - `unpaid_refused_cancel_requested_allowed`;
  - `twenty_first_download_in_an_hour_rate_limited`;
  - `same_copy_code_on_repeat` (two issues give one `paper_copies` row);
  - `replaced_paper_new_copy_old_code_still_found` (replacement without a reason after a copy is `invalid_input`; with a reason it gives a new code; `paper_lookup_codes` finds both, with `current` false for the old one);
  - `cancelled_booking_keeps_copy_but_cannot_download`;
  - `exam_code_locked_after_first_copy`;
  - `booking_paper_state_reports_corrected` (after a download of version 1 and a replacement, `corrected` is true; after downloading version 2 it is false);
  - `copy_code_check_character` (valid codes pass, one changed character fails);
  - `family_cannot_read_paper_objects` (as a student, `storage.objects` in `exam-papers` returns 0 rows).
- [ ] **Step 2: Run** `npm run db:test:local`. Expected: `025` fails.
- [ ] **Step 3: Write the migration.**
- [ ] **Step 4: Run** `npx supabase db reset && npm run db:test:local`. Expected: all pass.
- [ ] **Step 5: Regenerate types. Commit** `feat(db): question papers, personalised copies and timed release`.

### Task 6: Building a copy (Edge shared module)

**Files:**
- Create: `supabase/functions/_shared/paper/stamp.ts`, `supabase/functions/_shared/paper/stamp.test.ts`
- Modify: `supabase/functions/deno.json` (imports `"pdf-lib": "npm:pdf-lib@1.17.1"`, `"qrcode": "npm:qrcode@1.5.4"`, `"jsqr": "npm:jsqr@1.4.0"` for tests)

**Interfaces:**
- Produces:
  - `const A4 = { width: 595.28, height: 841.89 }`, `const TOP_BAND = 34`, `const BOTTOM_BAND = 64`, `const SIDE = 18` (points).
  - `fitPage(width: number, height: number): { rotate: 0 | 90; scale: number; x: number; y: number }`: places a source page inside the box between the bands, turning landscape pages 90° and never scaling up above 1.
  - `qrPayload(code: string, page: number): string` returns `SX1.<code>.<page>`.
  - `inspectPaper(bytes: Uint8Array): Promise<{ pageCount: number }>`, which throws `PaperError("encrypted" | "unreadable")`.
  - `buildCopy(master: Uint8Array, info: { candidateName: string; indexNumber: string; examCode: string; examDate: string; code: string; sparePages: number }): Promise<Uint8Array>`. Top band text: `"{candidateName} · {indexNumber}"` on the left, `"{examCode} · {examDate}"` on the right. Bottom band: `"Page n of N"`, the QR (at least 52 pt square, error correction level M, a quiet zone of 4 modules), and `"{code 4}-{code 4}-{check} · p{nn}"` under it. Spare pages: lined, headed "Additional answer page", with a "Question number" box.

- [ ] **Step 1: Tests** in `stamp.test.ts`:
  - `fit_a4_portrait_no_rotation` (rotate 0, scale ≤ 1, content inside the bands);
  - `fit_landscape_rotates` (842×595 gives rotate 90);
  - `fit_a3_scales_down` (842×1191 gives scale < 0.71);
  - `payload_format` (`qrPayload("7KQ2M9XDQ", 3)` is `"SX1.7KQ2M9XDQ.3"`);
  - `copy_has_paper_plus_spare_pages_all_a4` (a 3-page master of A4, landscape and A3 built with pdf-lib in the test, `sparePages` 2, gives 5 pages, each `595.28 × 841.89`);
  - `qr_modules_decode` (render the QR matrix used for page 1 into an RGBA bitmap and decode with jsQR to `SX1.<code>.1`);
  - `encrypted_master_refused` (`inspectPaper` throws `encrypted`).
- [ ] **Step 2: Run** `deno test --config supabase/functions/deno.json supabase/functions/_shared/paper/`. Expected: FAIL.
- [ ] **Step 3: Implement** with pdf-lib (`embedPages` once per master, then `drawPage` per copy page) and `qrcode.create(payload, { errorCorrectionLevel: "M" })`, drawing the dark modules as one SVG path.
- [ ] **Step 4: Run** the tests. Expected: PASS. Also time `buildCopy` for a 20-page master in the test log; it must stay well under 1 second of processing.
- [ ] **Step 5: Commit** `feat(functions): build personalised paper copies`.

### Task 7: `paper-register` and `paper-copy` (Edge Functions)

**Files:**
- Create: `supabase/functions/paper-register/index.ts` (+ `index.test.ts`), `supabase/functions/paper-copy/index.ts` (+ `index.test.ts`)
- Modify: `supabase/config.toml` (both functions with `verify_jwt = true`), `packages/shared/src/functions.ts`, `packages/shared/src/errors.ts`

**Interfaces:**
- Consumes: `inspectPaper` and `buildCopy` (Task 6); `register_exam_paper`, `paper_copy_issue`, `paper_download_log` and `paper_insert_issue` (Task 5). SQL functions are called with a client built from the anon key and the caller's `Authorization` header, so `auth.uid()` is the caller; storage is read with `serviceClient()`.
- Produces:
  - `POST paper-register {examId, kind: "paper" | "insert", title?, storagePath, reason?}`: owner/admin. Downloads the object (refuses over 40 MB), runs `inspectPaper`, calls `register_exam_paper`, and deletes the object on any refusal. Returns `{paperId, version, pageCount}`.
  - `POST paper-copy {bookingId, kind: "home" | "print_pack" | "reprint" | "admin_preview"}` returns `application/pdf` with `Content-Disposition: attachment; filename="<examCode>-<indexNumber>.pdf"`, logged only after the PDF is built, plus an `X-Paper-Differs` header (`1` when `differs_from_previous`). `POST paper-copy {bookingId, insertId}` returns the insert file unchanged.
  - Error codes added to `packages/shared/src/errors.ts` with the Global Constraints family texts: `paper_missing`, `paper_held`, `paper_not_released`, `paper_closed`, `wrong_sitting`, `paper_unreadable`, `paper_encrypted`, `paper_too_large`.
  - In `functions.ts`: `registerExamPaper(client, input: { examId: string; kind: "paper" | "insert"; title?: string; storagePath: string; reason?: string })` returning `FunctionResult<{ paperId: string; version: number; pageCount: number }>`, and `downloadPaperCopy(client, input: { bookingId: string; kind: "home" | "print_pack" | "reprint" | "admin_preview" } | { bookingId: string; insertId: string }): Promise<{ data: { blob: Blob; fileName: string; differs: boolean } } | { error: AppError }>` using `fetch` with the session token, because `functions.invoke` parses JSON.

- [ ] **Step 1: Integration tests** (`fn:test:local`):
  - `copy_before_release_is_409`;
  - `copy_after_release_is_pdf_and_logged` (the body starts with `%PDF`; one `paper_downloads` row);
  - `failed_build_is_not_logged` (point the paper at a non-PDF object: 422 and no log row);
  - `other_parent_forbidden`;
  - `register_refuses_encrypted_and_deletes_object`;
  - `register_non_admin_forbidden`;
  - `insert_download_after_release`.
- [ ] **Step 2: Run** and confirm FAIL. **Step 3: Implement. Step 4: Run** and confirm PASS.
- [ ] **Step 5: Commit** `feat(functions): paper-register and paper-copy`.

### Task 8: Admin exam page: paper, release, print packs (web)

**Files:**
- Create: `apps/web/src/app/admin/exams/[id]/page.tsx`, `actions.ts`, `apps/web/src/components/papers/PaperPanel.tsx`, `ReleasePanel.tsx`, `PrintPanel.tsx`, `DownloadLog.tsx`, `apps/web/src/lib/print-pack.ts` (+ `print-pack.test.ts`)
- Modify: `apps/web/package.json` (add `pdf-lib@1.17.1`), `components/exams/ExamsManager.tsx` (a link to each exam's page, and the missing-paper warning), `apps/web/src/app/admin/page.tsx` (the warning), `apps/web/src/app/teacher/exams/*` (no paper access)

**Interfaces:**
- Consumes: `registerExamPaper` and `downloadPaperCopy` (Task 7); `set_exam_paper_settings`, `paper_release_now`, `paper_hold`, `paper_resume`, `remove_exam_insert` and `paper_release_at` (Task 5).
- Produces:
  - `buildPrintPack(copies: Uint8Array[], cover: { examTitle: string; examCode: string; centre: string; room: string; date: string; candidates: number; paperVersion: number; madeAt: string }): Promise<Uint8Array>` (cover page first, then each copy in order).
  - `missingPaperWarning(exam: { status: string; hasPaper: boolean; releaseAt: string }, now: Date): boolean` (true when published, no paper, and within 24 hours of release).

- [ ] **Step 1: Vitest:** `print_pack_cover_then_copies_in_order` (three one-page copies give 4 pages); `missing_paper_warning_window` (25 h false, 23 h true, has paper false).
- [ ] **Step 2: Run** and confirm FAIL. **Step 3: Implement** the page:
  - Paper: upload to `exam-papers/<examId>/<uuid>.pdf` with the admin's session, then `registerExamPaper`; a replace dialog with a reason once copies exist; version history.
  - Inserts: add and remove.
  - Settings: exam code, release minutes, spare pages.
  - Release: the release time in London time, the status, and Release now / Hold / Resume, each with a reason.
  - Print: per centre, **Print pack** fetches copies one at a time (at most 3 at once) with a progress bar, then saves the merged PDF. **Reprint** per candidate warns when `X-Paper-Differs` is `1`.
  - Download log table.
- [ ] **Step 4: Run** unit tests, typecheck, lint. **Step 5: Playwright** `papers-admin.spec.ts`: `admin_uploads_paper_and_sees_version_1`, `replace_requires_reason_after_download`, `print_pack_has_cover_and_all_centre_candidates`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(web): admin exam page with paper, release and print packs`.

### Task 9: Family paper downloads (web)

**Files:**
- Create: `apps/web/src/lib/paper-state.ts` (+ `paper-state.test.ts`), `apps/web/src/components/papers/BookingPaper.tsx`
- Modify: `apps/web/src/app/account/bookings/page.tsx`

**Interfaces:**
- Consumes: `booking_paper_state` (Task 5), `downloadPaperCopy` (Task 7).
- Produces: `paperMessage(state: BookingPaperState, now: Date): { text: string; action: "download" | "none" }`, using exactly the Global Constraints texts and London times.

- [ ] **Step 1: Vitest:** one case per status (`centre`, `missing`, `not_yet` with "Your paper will be ready at 09:50 on Saturday 5 June", `held`, `open`, `closed`), plus `booking_paper_state_reports_corrected` and `downloaded_line_names_the_person`.
- [ ] **Step 2: Run** and confirm FAIL. **Step 3: Implement** the booking card section (download saves the blob under the server's file name; inserts listed with their own download buttons).
- [ ] **Step 4: Run** tests, typecheck, lint, and Playwright `papers-family.spec.ts`: `home_candidate_downloads_after_release`, `parent_downloads_for_child`, `before_release_shows_ready_time`, `centre_booking_shows_exam_room_message`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(web): families download personalised papers at release`.

### Task 10: Scan check (web)

**Files:**
- Create: `apps/web/src/app/admin/exams/scan-check/page.tsx`, `apps/web/src/components/papers/ScanCheck.tsx`, `apps/web/src/lib/paper-payload.ts` (+ `paper-payload.test.ts`)
- Modify: `apps/web/package.json` (move `jsqr` to `dependencies`), `components/exams/ExamsManager.tsx` ("Check a scan" link)

**Interfaces:**
- Consumes: `paper_lookup_codes` (Task 5).
- Produces: `parsePagePayload(text: string): { code: string; page: number } | null` (accepts only `^SX1\.([0-9A-HJKMNP-TV-Z*~$=U]{9})\.([1-9][0-9]{0,2})$`).

- [ ] **Step 1: Vitest:** `parses_valid_payload`, `rejects_other_prefix`, `rejects_page_zero`, `rejects_lowercase_or_extra_text`.
- [ ] **Step 2: Run** and confirm FAIL. **Step 3: Implement:** accept images (JPEG, PNG, HEIC refused with a message) and PDFs (each page rendered with pdfjs-dist at 2× scale); decode with jsQR; look up all codes in one call; table "File / page · Exam · Page n of N · Index number · Version" with "No code found on page n" rows. Store nothing.
- [ ] **Step 4: Run** tests, typecheck, lint. Playwright `scan_check_reads_a_generated_copy`: generate a copy via `admin_preview`, upload it to the scan check, and expect every page's index number and "Page n of N". Expected: PASS.
- [ ] **Step 5: Commit** `feat(web): scan check reads printed paper codes`.

### Task 11: Release emails

**Files:**
- Create: `supabase/migrations/20261118000049_paper_release_notify.sql`, `supabase/functions/paper-release-notify/index.ts` (+ `index.test.ts`)
- Modify: `supabase/functions/_shared/email.ts` (templates `paper_released`, `paper_corrected`), `supabase/config.toml` (`verify_jwt = false` for this function), `docs/superpowers/2026-11-10-part1-decisions-and-launch.md` (launch item L13)

**Interfaces:**
- Consumes: `paper_release_at`, `exams.release_notified_at`, `exam_papers.corrected_notified_at` (Task 5).
- Produces: `POST paper-release-notify` with header `x-cron-secret` equal to the function secret `CRON_SECRET` (anything else: 401). It emails the active candidate and active linked parents of each `paid` or `cancel_requested` home booking for exams released in the last 6 hours that are not held and not yet notified, then sets `release_notified_at`. It also emails families who downloaded a superseded paper version once (`corrected_notified_at`). A pg_cron job `paper-release-notify` runs every minute and calls it through `pg_net`, reading the URL and secret from Vault names `paper_notify_url` and `cron_secret`; with either missing, the job does nothing.

- [ ] **Step 1: Tests:** `wrong_secret_401`; `released_exam_notified_once` (two calls, `release_notified_at` set, console provider, emails counted through the test seam); `held_exam_not_notified`; `corrected_paper_notifies_downloaders_once`.
- [ ] **Step 2: Run** and confirm FAIL. **Step 3: Implement. Step 4: Run** and confirm PASS.
- [ ] **Step 5:** Add launch item L13 (set `CRON_SECRET`, and the Vault secrets `paper_notify_url` and `cron_secret`, on the live project before relying on release emails).
- [ ] **Step 6: Commit** `feat: email families when their paper is released or corrected`.

### Task 12: Whole-branch check

- [ ] **Step 1:** `npx supabase db reset`, then `npm run db:test:local`, `npm run fn:test:local`, `npm test -w @stem/web`, `npx tsc --noEmit -p apps/web`, `npx eslint apps/web/src apps/web/e2e`, the whole Playwright suite locally, and `npm run build -w @stem/web`. Expected: all pass.
- [ ] **Step 2:** Visual check at 1440, 768 and 390 wide: the booking screen with both sittings and two centres, the admin exam page, and the family paper card. No sideways scroll and no console errors.
- [ ] **Step 3:** Write `docs/superpowers/2026-11-18-phase1a-release-notes.md`: what changed, the deploy order (migrations 045 to 049, then the Edge Functions `paper-register`, `paper-copy` and `paper-release-notify`, then the website, all within a few minutes because the old website cannot read the new exam shape), and the owner pilot steps (print, photograph, scan, check). Do not deploy.
- [ ] **Step 4: Commit** `docs: Phase 1A release notes`.
