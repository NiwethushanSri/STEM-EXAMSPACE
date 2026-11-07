# Stem Examspace Part 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the mock login and registration with real Supabase accounts, roles, approval and profile completion across a web staff app, a Tauri desktop shell and an Expo mobile app.

**Architecture:** npm-workspaces monorepo. Supabase (Postgres + RLS + Auth + Storage + Edge Functions) is the only backend; apps use the anon key with the user's session, privileged actions go through Edge Functions using the service role. Staff screens are built once in `apps/web` and wrapped by `apps/desktop`; student/parent screens are built in `apps/mobile`.

**Tech Stack:** Next.js 16.4 (React 19.3, Tailwind 4), Supabase CLI + `@supabase/supabase-js` v2 + `@supabase/ssr`, Deno (Edge Functions), pgTAP, Vitest, Playwright, Tauri v2, Expo (expo-router, expo-secure-store), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-11-07-crm-foundation-design.md` (read it before any task; section numbers below refer to it).

## Global Constraints

- Next.js stays at the version in `package.json` (16.4.x). Before writing Next code, read the relevant guide in `apps/web/node_modules/next/dist/docs/` (AGENTS.md rule). Route protection lives in `proxy.ts` (Next 16 name for middleware), next to `app/`.
- Roles enum, exact values: `owner, admin, teacher, tutor, corrector, student, parent`.
- Status enum, exact values: `unconfirmed, pending, profile_incomplete, active, suspended`.
- Index number format: `SE-<year of approval>-<4-digit zero-padded sequence>`, e.g. `SE-2026-0142`; sequence restarts each calendar year.
- Seed subjects: school = Maths, Further Maths, Physics, Chemistry, Biology, Computer Science; entrance = TMUA, FSAT, UCAT.
- No app or client bundle ever contains the service-role key. Only Edge Functions and `scripts/setup-owner.ts` use it.
- Edge Functions read the caller's role from `profiles`, never from JWT claims or request body.
- Edge Function errors are `{ error: { code, message } }` with HTTP status; codes are the `ErrorCode` union in Task 6.
- Supabase project region: London (eu-west-2).
- Signed photo URLs expire after 60 seconds.
- Unconfirmed sign-ups are deleted after 7 days.
- index-login rate limit: 5 failed attempts per 15 minutes, per IP and per index number.
- Audit rows for rejection/expiry/self-deletion carry no target id and no personal data.
- **Hosted dev database (user decision, replaces local Docker):** no `supabase start`, no Docker. All DB and function work targets the hosted project `stem-examspace-dev` (London), already linked with `npx supabase link` (ref `jmhjahwfskhlgagaqlrz`). Always pass bare `--remote` (the linked dev project); never `--remote=<anything>` and never `--project-ref` of another project — the same Supabase account holds unrelated production projects. Commands: apply migrations `npx supabase db push`; wipe and rebuild `npx supabase db reset --remote` (dev only, allowed); pgTAP `npx supabase test db --remote`; functions `npx supabase functions deploy <name>` then Deno tests call `${SUPABASE_URL}/functions/v1/<name>`. Credentials come from git-ignored `.env.dev.local` at repo root (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`), filled by the user; never print, log or commit them. Never run any command against a project other than the linked dev project. Every pgTAP file wraps its work in `BEGIN; … ROLLBACK;` so tests leave no rows behind. Function tests delete the users they create. Tests create users via SQL or `auth.admin.createUser({ email_confirm })` / `auth.admin.generateLink`, not via real email, so the hosted email rate limit is never hit. Browser tests that need real sign-up email (Tasks 12–13) require custom SMTP on the dev project; the controller asks the user to set that up before Task 12. `.env*.example` files must be un-ignored with `!.env*.example` in `.gitignore`.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Work on `main` (user's choice).

## Review Focus

1. **Approving a student whose parent email already has a parent account (sibling)** → the child is linked to the existing parent; no second parent account, no invite email. Test: Task 7 `approve_links_existing_parent`.
2. **Mixed-case or padded emails** (`Nimal.Perera@Example.com `) at sign-up and as parent email → treated as the same address as the lowercase form. Test: Task 3 `signup_normalises_email` and Task 7 `approve_matches_parent_email_case_insensitively`.
3. **Index number typed with lowercase or spaces** (`se-2026-0142`, `SE 2026 0142`) at index login → signs in. Test: Task 9 `index_login_normalises_input`.
4. **Two admins approving at the same moment** → two distinct index numbers, no error. Test: Task 7 `concurrent_approvals_get_distinct_index_numbers`.
5. **Year rollover** → the first approval in a new calendar year gets `SE-<new year>-0001`. Test: Task 7 `index_sequence_restarts_each_year`.

---

### Task 0: Prerequisites (owner does these; not code)

- [ ] **Step 1:** Install Docker Desktop (needed by `supabase start`) and start it. Check: `docker info` succeeds.
- [ ] **Step 2:** Install Deno 2. Check: `deno --version`.
- [ ] **Step 3:** Install Rust (rustup) and the Tauri v2 Windows prerequisites (WebView2 is already on Windows 11; MSVC build tools). Check: `cargo --version`.
- [ ] **Step 4:** Create a Supabase project in region London; keep its URL, anon key, service-role key in a password manager. Not needed until Task 15 (local Supabase is used before that).

---

### Task 1: Monorepo with `apps/web` and `packages/shared`

**Files:**
- Move: everything app-related at repo root (`src/`, `public/`, `next.config.ts`, `postcss.config.mjs`, `eslint.config.mjs`, `tsconfig.json`, `AGENTS.md`) → `apps/web/`
- Create: `package.json` (root, workspaces `apps/*`, `packages/*`), `apps/web/package.json` (name `@stem/web`, current deps/scripts), `packages/shared/package.json` (name `@stem/shared`), `packages/shared/tsconfig.json`, `packages/shared/src/index.ts`
- Move: `apps/web/src/lib/forecast.ts`, `progress.ts` → `packages/shared/src/` (they import `TestResult` from site-data: move that type into `packages/shared/src/types.ts`)
- Test: `packages/shared/src/forecast.test.ts`, `packages/shared/src/progress.test.ts`

**Interfaces:**
- Produces: `@stem/shared` exporting `linearForecast`, `buildTracker`, `termOf`, `termLabel`, `feedbackFor`, `TestResult`, unchanged signatures. `apps/web` imports them from `@stem/shared`.

- [ ] **Step 1:** `git mv` files into `apps/web`, create root and package manifests, `npm install` at root. Delete root `package-lock.json` first so a single workspace lockfile is generated.
- [ ] **Step 2:** Write Vitest tests pinning current behaviour before moving logic: `linearForecast([52,55,61,71], 2)` returns 2 points both > 71; `termOf(new Date("2026-10-12"))` is `{ name: "Autumn", year: 2026 }`; `buildTracker(testHistory physics rows)` returns non-empty tracker. Use the actual outputs from running the current code as expected values.
- [ ] **Step 3:** Move the files, update imports in `apps/web`.
- [ ] **Step 4:** Run `npm test -w @stem/shared` → PASS; `npm run build -w @stem/web` → succeeds; `npm run dev -w @stem/web` and the home page and `/student/analysis` render as before.
- [ ] **Step 5:** Update `.claude/launch.json` to `npm run dev -w @stem/web`. Commit `chore: move app into npm workspaces monorepo`.

---

### Task 2: Local Supabase and base schema

**Files:**
- Create: `supabase/config.toml` (via `npx supabase init`), `supabase/migrations/20261107000001_base_schema.sql`, `supabase/seed.sql`, `supabase/tests/001_schema.test.sql`
- Modify: root `package.json` add devDependency `supabase` and scripts `db:start`, `db:reset`, `db:test` (`supabase test db`)
- Modify: `supabase/config.toml`: `[auth.email] enable_confirmations = true`; enable `pg_cron` extension in the migration

**Interfaces:**
- Produces: enums `app_role`, `account_status`, `subject_kind ('school','entrance')`; tables exactly as spec §7 (`profiles`, `student_details`, `subjects`, `student_subjects`, `parent_children`, `teacher_subjects`, `tutor_students`, `audit_log`). `profiles.id` FK `auth.users(id) ON DELETE CASCADE`; all child FKs `ON DELETE CASCADE`. `profiles.email` is `citext UNIQUE`. RLS enabled on every table with no policies yet (deny all).

- [ ] **Step 1:** Write pgTAP test `001_schema.test.sql`: `has_table` for all 8 tables; `enum_has_labels('app_role', ARRAY['owner','admin','teacher','tutor','corrector','student','parent'])`; same for `account_status` with the 5 labels; 9 rows in `subjects` with the seed names; every table has `relrowsecurity = true`.
- [ ] **Step 2:** `npm run db:start && npm run db:test` → FAIL (tables missing).
- [ ] **Step 3:** Write the migration and `seed.sql` (subjects only).
- [ ] **Step 4:** `npm run db:reset && npm run db:test` → PASS.
- [ ] **Step 5:** Commit `feat(db): base schema, enums and seed subjects`.

---

### Task 3: Sign-up, confirmation and guard triggers

**Files:**
- Create: `supabase/migrations/20261107000002_auth_triggers.sql`, `supabase/tests/002_auth_triggers.test.sql`

**Interfaces:**
- Produces:
  - `handle_new_user()` trigger AFTER INSERT on `auth.users`. If `raw_app_meta_data->>'invited_role'` is set (only settable with service role) → profile with that role, status `active`. Otherwise → role `student`, status `unconfirmed`, plus `student_details` from `raw_user_meta_data` keys `first_name, last_name, date_of_birth, school, parent_name, parent_email` (parent email lowercased and trimmed into `signup_parent_email`). Any `role`/`status` keys in `raw_user_meta_data` are ignored.
  - `handle_email_confirmed()` trigger AFTER UPDATE OF `email_confirmed_at` on `auth.users`: `unconfirmed` → `pending`.
  - `guard_protected_columns()` BEFORE UPDATE on `profiles` and `student_details`: raises if `role`, `status` or `index_number` change unless `current_setting('app.bypass_guard', true) = 'on'` or `auth.role() = 'service_role'`.

- [ ] **Step 1:** Write tests (insert into `auth.users` directly as in Supabase pgTAP docs):
  - `signup_creates_pending_student_profile`: insert user with metadata → profile role `student`, status `unconfirmed`, `student_details.school` matches.
  - `signup_ignores_role_in_metadata`: metadata `{"role":"owner","status":"active"}` → role `student`, status `unconfirmed`.
  - `signup_normalises_email`: user email `Nimal.Perera@Example.com ` stored in `profiles.email` equal to `nimal.perera@example.com`; parent email the same.
  - `confirming_email_sets_pending`: update `email_confirmed_at = now()` → status `pending`.
  - `invited_role_is_applied`: `raw_app_meta_data = {"invited_role":"tutor"}` → role `tutor`, status `active`.
  - `user_cannot_change_own_role`: as `authenticated` with that user's JWT, `update profiles set role='owner'` → throws.
- [ ] **Step 2:** `npm run db:test` → FAIL.
- [ ] **Step 3:** Write the migration (functions `SECURITY DEFINER`, `search_path = ''`).
- [ ] **Step 4:** `npm run db:reset && npm run db:test` → PASS.
- [ ] **Step 5:** Commit `feat(db): sign-up, confirmation and protected-column triggers`.

---

### Task 4: RLS policies

**Files:**
- Create: `supabase/migrations/20261107000003_rls.sql`, `supabase/tests/003_rls.test.sql`, `supabase/tests/helpers.sql` (functions `tests.create_user(role, status) returns uuid` and `tests.as_user(uuid)` that sets `request.jwt.claims` and `role authenticated`)

**Interfaces:**
- Produces: `public.current_role() returns app_role` (SECURITY DEFINER, reads `profiles` for `auth.uid()`), `public.is_staff_admin() returns boolean` (owner or admin). Policies exactly as spec §8.

- [ ] **Step 1:** Write the role × table test matrix. Minimum cases:
  - student reads own profile/details (1 row), not another student's (0 rows).
  - parent reads linked child (1 row), not an unlinked student (0).
  - tutor reads assigned student (1), not unassigned (0).
  - teacher and corrector read 0 rows of `student_details`.
  - admin and owner read all students.
  - any signed-in user reads 9 subjects; student insert into `subjects` → throws.
  - student update of `student_details.parent_phone` directly → 0 rows changed (only via completion function, Task 5).
  - admin `update audit_log` and `delete from audit_log` → 0 rows affected/throws; admin select works.
  - anon role reads 0 rows from every table.
- [ ] **Step 2:** `npm run db:test` → FAIL.
- [ ] **Step 3:** Write policies.
- [ ] **Step 4:** `npm run db:reset && npm run db:test` → PASS.
- [ ] **Step 5:** Commit `feat(db): row-level security policies`.

---

### Task 5: Profile completion and photo storage

**Files:**
- Create: `supabase/migrations/20261107000004_profile_completion.sql`, `supabase/tests/004_profile_completion.test.sql`

**Interfaces:**
- Produces: RPC `complete_profile(p_gender text, p_year_group text, p_subject_ids uuid[], p_parent_phone text, p_photo_path text default null) returns void`. Only for the caller, only when status is `profile_incomplete`; validates gender ∈ (`Female`,`Male`,`Prefer not to say`), year group ∈ (`Year 10`,`Year 11`,`Year 12`,`Year 13`,`University applicant`), ≥1 active subject, non-empty phone; writes details + `student_subjects`, sets status `active` with `app.bypass_guard`. Storage bucket `student-photos` (private); policy: a user may write/read only `<auth.uid()>/photo.jpg`; admin/owner may read all.

- [ ] **Step 1:** Tests: `complete_profile_activates_student`; `complete_profile_rejects_when_pending` (throws); `complete_profile_rejects_empty_subjects`; `complete_profile_rejects_unknown_year_group`; `student_cannot_upload_to_other_folder` (insert into `storage.objects` with another uid's prefix → throws).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(db): profile completion RPC and photo bucket`.

---

### Task 6: Edge Function shared module

**Files:**
- Create: `supabase/functions/_shared/errors.ts`, `_shared/auth.ts`, `_shared/email.ts`, `_shared/audit.ts`, `_shared/auth.test.ts`, `supabase/functions/deno.json`
- Create: `packages/shared/src/errors.ts` re-exporting the type from `../../../supabase/functions/_shared/errors.ts` (single source)

**Interfaces:**
- Produces:
  - `type ErrorCode = "unauthenticated" | "forbidden" | "not_found" | "conflict" | "invalid_input" | "parent_email_is_staff" | "email_in_use" | "rate_limited" | "invalid_credentials" | "internal"`
  - `errorResponse(code: ErrorCode, message: string, status: number): Response`
  - `requireCaller(req: Request, allowed: AppRole[]): Promise<{ id: string; role: AppRole }>` — verifies JWT with anon client, loads role from `profiles` with service client, throws `HttpError` (`unauthenticated` 401 / `forbidden` 403).
  - `serviceClient(): SupabaseClient`
  - `sendEmail(to: string, template: "approved" | "rejected", data: Record<string,string>): Promise<boolean>` — returns false on failure, never throws. Uses Supabase SMTP via `auth.admin` for invites; for other templates logs to console locally (`EMAIL_PROVIDER=console`) and uses Resend API when `EMAIL_PROVIDER=resend`.
  - `writeAudit(actorId: string | null, action: string, targetType?: string, targetId?: string): Promise<void>`

- [ ] **Step 1:** Deno tests: `requireCaller` with no Authorization header → 401 `unauthenticated`; with a student JWT and `allowed=["admin"]` → 403 `forbidden`; role taken from DB even if JWT `user_metadata.role = "owner"`.
- [ ] **Step 2:** `deno test --allow-all supabase/functions/_shared` (local Supabase running) → FAIL.
- [ ] **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(functions): shared auth, errors, email and audit helpers`.

---

### Task 7: `approve-student`

**Files:**
- Create: `supabase/migrations/20261107000005_approve.sql`, `supabase/functions/approve-student/index.ts`, `supabase/functions/approve-student/index.test.ts`, `supabase/tests/005_approve.test.sql`

**Interfaces:**
- Consumes: Task 6 helpers.
- Produces:
  - SQL `approve_student_tx(p_student uuid, p_actor uuid, p_year int default extract(year from now())::int) returns table(index_number text, parent_id uuid, parent_created boolean)`, executable by `service_role` only. In one transaction: lock the student row `FOR UPDATE`; require `pending` else raise `conflict`; next number from table `index_counters(year int primary key, last int)` via `INSERT … ON CONFLICT (year) DO UPDATE SET last = index_counters.last + 1 RETURNING last`; set index number and status `profile_incomplete`; find parent profile by `lower(email) = signup_parent_email`: role `parent` → link; other role → raise `parent_email_is_staff`; none → return `parent_created = true` with null id; write audit `student_approved`.
  - HTTP `POST /approve-student` body `{ studentId: string }` → 200 `{ indexNumber, parentInvited: boolean, emailsSent: boolean }`. Allowed: owner, admin. When `parent_created`, calls `auth.admin.inviteUserByEmail(parentEmail, { data: {...} })` with `app_metadata.invited_role = "parent"` (set via `auth.admin.updateUserById` right after), then inserts `parent_children`. Sets `profiles.invite_sent_at` for parent on success. Email failure → still 200 with `emailsSent: false`.

- [ ] **Step 1:** pgTAP tests: `approve_assigns_index_and_status` (`SE-2026-0001`, status `profile_incomplete`, tests pass `p_year => 2026`); `index_sequence_restarts_each_year` (2026 → `0001`,`0002`; 2027 → `SE-2027-0001`); `approve_links_existing_parent`; `approve_matches_parent_email_case_insensitively`; `approve_rejects_staff_parent_email` (throws `parent_email_is_staff`); `approve_twice_conflicts`.
- [ ] **Step 2:** Deno tests: student caller → 403; admin approves → 200 and parent invite created in `auth.users`; `concurrent_approvals_get_distinct_index_numbers` (two pending students, `Promise.all` of two approvals → two different index numbers).
- [ ] **Step 3:** Run both → FAIL. **Step 4:** Implement. **Step 5:** Run → PASS (`npx supabase functions serve` running).
- [ ] **Step 6:** Commit `feat: approve-student function with index numbers and parent linking`.

---

### Task 8: `reject-student` and expiry job

**Files:**
- Create: `supabase/functions/reject-student/index.ts` + `index.test.ts`, `supabase/migrations/20261107000006_expire_unconfirmed.sql`, `supabase/tests/006_expire.test.sql`

**Interfaces:**
- Produces:
  - `POST /reject-student` `{ studentId }` → 200 `{ emailSent: boolean }`. Owner/admin only. Student must be `pending` else 409 `conflict`. Order: read email, send `rejected` email, `auth.admin.deleteUser`, `writeAudit(actor, "registration_rejected")` with no target.
  - SQL `expire_unconfirmed(p_now timestamptz default now()) returns int` deleting auth users whose profile is `unconfirmed` and `created_at < p_now - interval '7 days'`, writing one `registration_expired` audit row each (null actor, no target). Scheduled daily 03:00 with `pg_cron`.

- [ ] **Step 1:** Tests: reject removes `auth.users`, `profiles`, `student_details` rows; audit row has null `target_id`; rejecting an `active` student → 409; same email can sign up again after rejection; `expire_unconfirmed` deletes an 8-day-old unconfirmed user and keeps a 6-day-old one and an 8-day-old `pending` one.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: reject-student and unconfirmed expiry`.

---

### Task 9: `index-login`

**Files:**
- Create: `supabase/migrations/20261107000007_login_attempts.sql` (table `login_attempts(key text, attempted_at timestamptz)`, RLS on, no policies), `supabase/functions/index-login/index.ts` + `index.test.ts`

**Interfaces:**
- Produces: `POST /index-login` `{ indexNumber: string, password: string }` (no auth header needed) → 200 `{ access_token, refresh_token, expires_in }` or 401 `invalid_credentials` (message always `"Index number or password is incorrect."`) or 429 `rate_limited`. Normalise: uppercase, strip spaces, insert dashes if `SE2026XXXX` form. Rate keys `ip:<x-forwarded-for first>` and `idx:<normalised>`; >5 failures in 15 min on either key → 429 before checking the password. Success clears that index key.

- [ ] **Step 1:** Tests: correct index + password → tokens, response body has no `email`; wrong password and unknown index → identical 401 body; `index_login_normalises_input` (`se 2026 0001` works); 6th failed attempt within 15 min → 429.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: index-number login with rate limiting`.

---

### Task 10: `invite-user`, `account-admin`, `delete-my-account`, owner setup

**Files:**
- Create: `supabase/functions/invite-user/index.ts` + test, `supabase/functions/account-admin/index.ts` + test, `supabase/functions/delete-my-account/index.ts` + test, `scripts/setup-owner.ts`

**Interfaces:**
- Produces:
  - `POST /invite-user` `{ email, firstName, lastName, role }`. Owner may invite `admin|teacher|tutor|corrector`; admin may invite `teacher|tutor|corrector`; else 403. Existing email → 409 `email_in_use`. Creates invite with `app_metadata.invited_role`.
  - `POST /account-admin` `{ action: "suspend" | "reactivate" | "resend_invite" | "remove_staff", userId }`. Suspend/reactivate: owner/admin, not on owner accounts; admins cannot act on admins. `remove_staff` of an admin: owner only. All write audit rows.
  - `POST /delete-my-account` (caller only, roles student/parent) → deletes caller's auth user, audit `account_self_deleted` with no target.
  - `npm run setup:owner -- <email>`: uses `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` env, invites with `invited_role = "owner"`, refuses if an owner already exists.

- [ ] **Step 1:** Tests: admin inviting `admin` → 403; owner inviting `admin` → 200 and profile role `admin`; duplicate email → 409; admin suspending another admin → 403; suspended user's status is `suspended`; tutor calling `delete-my-account` → 403; parent deleting own account removes it.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: staff invites, account admin actions, self-deletion, owner setup`.

---

### Task 10c: Parents adding children (spec §6.9)

**Files:**
- Create: `supabase/migrations/<next>_parent_children_requests.sql`, `supabase/tests/0NN_parent_requests.test.sql`, `supabase/functions/parent-child/index.ts` + `index.test.ts`
- Modify: `supabase/functions/approve-student/index.ts` (link `requested_by_parent`), `supabase/functions/reject-student/index.ts` (unchanged behaviour; test that parent-initiated registrations reject the same way)

**Interfaces:**
- Produces:
  - `student_details.requested_by_parent uuid null` (FK profiles on delete set null).
  - `parent_link_requests(id uuid pk default gen_random_uuid(), parent_id uuid fk, student_id uuid fk, created_at, unique(parent_id, student_id))`, RLS: parent reads own rows; owner/admin read all; no client writes.
  - `POST /parent-child` `{ action: "register", child: { firstName, lastName, email, password, dateOfBirth, school } }` (caller role parent, status active) → creates the child via `auth.admin.createUser({ email, password, email_confirm: false, user_metadata: {…, parent_name, parent_email: caller email} })` then sends the confirmation link (`generateLink({ type: 'signup' })` + email), sets `requested_by_parent`; child follows §6.1 statuses. 200 `{ registered: true }`; existing email → 409 email_in_use.
  - `{ action: "link", indexNumber, dateOfBirth }` → rate-limited (reuse `login_attempt_begin` with keys `plink:<parent id>` and `pidx:<normalised index>`); match → insert request (idempotent) → 200 `{ requested: true }`; no match → padded generic 404 `not_found` "We could not find a child with those details".
  - `{ action: "approve_link" | "reject_link", requestId }` (owner/admin) → approve inserts `parent_children` + deletes request; reject deletes request. Audit ids only.
  - approve-student: after approval, also link `requested_by_parent` if set (and still a parent).
- [ ] **Step 1:** Tests (pgTAP + Deno): parent registers child → child unconfirmed; confirm → pending; admin approves → child linked to requesting parent; admin rejects → child deleted, no link; non-parent caller → 403; link with correct index+DOB → request pending, parent still cannot read child; wrong DOB and unknown index → identical 404 bodies; 6th wrong attempt → 429; admin approves request → parent reads child; reject → no link; parent cannot read other parents' requests.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS. **Step 5:** Commit `feat: parents register or link children with admin approval`.

---

### Task 11: Shared client and role routing

**Files:**
- Create: `packages/shared/src/supabase.ts`, `packages/shared/src/roles.ts`, `packages/shared/src/functions.ts`, `packages/shared/src/database.types.ts` (generated: `npx supabase gen types typescript --local`), `packages/shared/src/roles.test.ts`

**Interfaces:**
- Produces:
  - `createStemClient(url: string, anonKey: string, storage?: SupportedStorage): SupabaseClient<Database>`
  - `homeFor(role: AppRole, status: AccountStatus, platform: "web-staff" | "mobile"): string` — mobile: student `unconfirmed`→`/status/unconfirmed`, `pending`→`/status/pending`, `profile_incomplete`→`/profile/complete`, `active`→`/home`, `suspended`→`/status/suspended`; parent → `/home`; staff roles → `/use-desktop`. web-staff: owner→`/owner`, admin→`/admin`, teacher→`/teacher`, tutor→`/tutor`, corrector→`/corrector`; student/parent → their status path under `/account/…` (web fallback, same mapping as mobile with `/account` prefix).
  - `callFunction<T>(client, name: "approve-student" | "reject-student" | "invite-user" | "account-admin" | "index-login" | "delete-my-account", body: object): Promise<{ data: T } | { error: { code: ErrorCode; message: string } }>`
  - `messageFor(code: ErrorCode): string` with the copy from spec §10.

- [ ] **Step 1:** Vitest: table-driven test for every role × status × platform of `homeFor`; `messageFor("email_in_use")` equals `"An account with this email already exists. Sign in or reset your password."`; `messageFor("conflict")` equals `"This registration was already handled"`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(shared): supabase client, role routing and function caller`.

---

### Task 12: Web auth (login, register, reset, proxy)

Read first: `apps/web/node_modules/next/dist/docs/01-app/02-guides/authentication.md` and `01-getting-started/16-proxy.md`.

**Files:**
- Create: `apps/web/src/lib/supabase/server.ts`, `client.ts` (`@supabase/ssr`), `apps/web/src/proxy.ts`, `apps/web/src/app/reset-password/page.tsx`, `apps/web/src/app/auth/callback/route.ts`, `apps/web/src/app/account/[state]/page.tsx` (status screens per spec §6.1 table), `apps/web/.env.local.example` (`NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`)
- Modify: `apps/web/src/app/login/page.tsx` (remove role tabs; one form; identifier containing `@` → email login, else `index-login`; then redirect with `homeFor(…, "web-staff")`), `apps/web/src/app/register/page.tsx` (short form from spec §6.1, `supabase.auth.signUp` with metadata; keep the "Registration received" screen, text changed to "Check your email to confirm your address")
- Test: `apps/web/e2e/auth.spec.ts` (Playwright; reads confirmation links from local Supabase Inbucket/Mailpit at `http://127.0.0.1:54324`)

**Interfaces:**
- Consumes: Task 11 `homeFor`, `callFunction`, `messageFor`.
- Produces: `getSessionProfile(): Promise<{ id; role; status } | null>` in `server.ts`, used by staff pages. Proxy does optimistic redirect only: no session on `/admin|/owner|/teacher|/tutor|/corrector|/account` → `/login`; role mismatch → that role's home.

- [ ] **Step 1:** Playwright tests: `register_then_confirm_shows_pending` (register, open mail link, sign in → `/account/pending`); `duplicate_email_shows_message`; `student_cannot_open_admin` (redirected away from `/admin`); `wrong_password_shows_generic_error`.
- [ ] **Step 2:** `npx playwright test -c apps/web` → FAIL.
- [ ] **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(web): real sign-in, registration, reset and route protection`.

---

### Task 13: Web admin and owner account screens

**Files:**
- Modify: `apps/web/src/app/admin/accounts/page.tsx`, `apps/web/src/app/admin/page.tsx` (pending card uses real data)
- Create: `apps/web/src/app/admin/accounts/actions.ts` (server actions calling functions with the user's session), `apps/web/src/components/accounts/PendingTable.tsx`, `AccountsTable.tsx`, `InviteStaffDialog.tsx`, `ConfirmDialog.tsx`, `apps/web/src/app/owner/page.tsx`, `apps/web/src/app/owner/layout.tsx`
- Modify: `apps/web/src/components/AppShell.tsx` (add `owner` nav: Dashboard, Accounts, Staff; show signed-in name; sign out)
- Create: placeholder homes `apps/web/src/app/teacher/page.tsx`, `tutor/page.tsx`, `corrector/page.tsx` (AppShell + "Your tools arrive in a later update"), so `homeFor` never routes to a 404. The existing `/examiner` mock pages stay untouched until Part 3.
- Test: `apps/web/e2e/admin-accounts.spec.ts`

**Interfaces:**
- Consumes: Task 7–10 functions via Task 11 `callFunction`; Task 12 `getSessionProfile`.
- Produces: pending list (name, school, date of birth, parent email, signed up date; Approve, Reject → ConfirmDialog "Reject and delete this registration? This cannot be undone."); all accounts table filterable by role and status with Suspend/Reactivate/Resend invite; "invite not sent" badge when `invite_sent_at` is null for an invited account; Invite staff dialog (role options depend on caller role); owner page adds admin invite/remove. On `conflict`, refresh list and show the `messageFor("conflict")` toast.

- [ ] **Step 1:** Playwright: `admin_approves_student_and_index_number_shows`; `admin_rejects_student_and_row_disappears` (and re-registration with same email works); `admin_invite_dialog_has_no_admin_option`; `owner_can_invite_admin`; `parent_email_is_staff_shows_message`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat(web): live admin and owner account management`.

---

### Task 14: Mobile app (Expo)

**Files:**
- Create: `apps/mobile` via `npx create-expo-app@latest apps/mobile --template default` (name `@stem/mobile`), then: `app/_layout.tsx` (session provider, redirects with `homeFor(…, "mobile")`), `app/(auth)/sign-in.tsx`, `app/(auth)/register.tsx`, `app/(auth)/forgot-password.tsx`, `app/status/[state].tsx`, `app/profile/complete.tsx`, `app/home.tsx` (student: photo via `createSignedUrl(path, 60)`, name, index number, "Your dashboard is coming soon"; parent: list of linked children), `app/settings.tsx` (sign out; Delete my account → confirm → `delete-my-account`), `app/use-desktop.tsx`, `src/supabase.ts` (`createStemClient` with an expo-secure-store adapter), `.env.example` (`EXPO_PUBLIC_SUPABASE_URL`, `EXPO_PUBLIC_SUPABASE_ANON_KEY`)
- Test: `apps/mobile/MANUAL_TEST.md` checklist

**Interfaces:**
- Consumes: Task 11, Task 5 `complete_profile`, Task 9 `index-login`, Task 10 `delete-my-account`.

- [ ] **Step 1:** Write `MANUAL_TEST.md` with: register → confirm email → pending screen; admin approves on web → app shows profile form on next open; complete profile with photo → home shows index number; sign in with index number in lowercase; parent opens invite link, sets password, signs in → sees child; tutor signs in → "use the desktop app"; delete account → signed out and cannot sign in again.
- [ ] **Step 2:** Implement screens.
- [ ] **Step 3:** `npx tsc --noEmit -p apps/mobile` → no errors; run every checklist item on Android emulator (and iOS simulator if a Mac is available; otherwise note it as not run).
- [ ] **Step 4:** Commit `feat(mobile): Expo app for student and parent sign-up, status and profile`.

---

### Task 15: Desktop shell (Tauri) and hosted environments

**Files:**
- Create: `apps/desktop` via `npm create tauri-app@latest` (vanilla TS, name `@stem/desktop`); `apps/desktop/src-tauri/tauri.conf.json` window URL from env `STEM_STAFF_URL` (default `http://localhost:3000/login`); `apps/desktop/README.md` (how to run against local and hosted web)
- Modify: `supabase/config.toml` auth redirect URLs to include the web callback and the Expo scheme `stemexamspace://`

- [ ] **Step 1:** `npm run tauri dev -w @stem/desktop` with web running → window opens on the login page; admin signs in and sees `/admin/accounts`; closing and reopening keeps the session.
- [ ] **Step 2:** Link the London Supabase project (`npx supabase link`), `npx supabase db push`, `npx supabase functions deploy`, run `setup:owner` with the owner's email. Check: owner receives the invite and can sign in on the web.
- [ ] **Step 3:** Commit `feat(desktop): Tauri staff shell; hosted Supabase config`.

---

### Task 16: CI

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1:** Workflow on push/PR: `npm ci`; `npm run lint -w @stem/web`; `npx tsc --noEmit` for web, shared, mobile; `npm test -w @stem/shared`; `supabase/setup-cli` action → `supabase start` → `supabase test db`; `deno test` for functions with `functions serve` in background; Playwright with web dev server against local Supabase.
- [ ] **Step 2:** Push and check the run is green: `gh run watch`.
- [ ] **Step 3:** Commit `ci: lint, types, unit, database, function and e2e tests`.
