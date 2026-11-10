# Stem Examspace CRM: Part 1, Foundation — Design

Date: 2026-11-07
Status: Draft for review

## 1. Purpose

Stem Examspace is a private CRM for one education institution that runs STEM mock exams for school-age students (Year 10 to university applicants). It is built and run by one person. It replaces the current clickable mockup (this repo, Next.js, no backend) with a real system.

Success for the whole project: students register and are approved by staff, sit mock exams (online or in person), have papers marked by correctors, and students and parents see results and reports, all with each person seeing only what their role allows.

Success for Part 1 (this spec): real accounts, login, roles, and the student registration → approval → profile completion flow work end to end on the web staff app, the desktop app and the mobile app, backed by Supabase with database-enforced access rules.

## 2. Decisions already made

| Topic | Decision |
|---|---|
| Roles | Distinct: owner, admin, teacher, tutor, corrector, student, parent |
| Parents | Own login, linked to one or more children |
| Public site | Kept (marketing home page), with online card payments (Part 2) |
| Delivery | Real store apps: Expo mobile app (students, parents) in App Store and Google Play; Tauri desktop app (staff) |
| Backend | Supabase (Postgres, Auth, Storage, Edge Functions), London region |
| Rejection | Delete the registration immediately |
| Sign-up | Short sign-up form, no parent confirmation step; admin approval creates the parent invite |
| Structure | Monorepo with three apps and a shared package |

## 3. Project decomposition

The full system is split into parts, each with its own spec, plan and build:

1. **Foundation (this spec):** monorepo, Supabase, login, roles, registration, approval, profile completion, staff invites, parent linking, audit log.
2. **Exams and money:** subjects admin, exams and timetable, enrolment/booking, Stripe payments (web only, see 9.2), attendance with index-number check.
3. **Papers and marking:** paper upload and allocation, the existing PDF marking tool on real storage, anonymous marking by index number, standardisation.
4. **Results and communication:** results, analysis and forecast, progress reports, notices, exam reminders, push notifications.
5. **Store release:** App Store and Google Play submission, desktop installers and auto-update.

Parts 2 to 4 reuse the existing mockup screens and logic where possible.

## 4. Architecture

```
stem-examspace/
  apps/
    web/        Next.js (existing code moved here): public site, staff screens, auth pages
    desktop/    Tauri v2 shell that loads the staff area of apps/web
    mobile/     Expo (React Native, expo-router): student and parent app
  packages/
    shared/     TypeScript types, Supabase client factory, role/permission helpers,
                pure logic moved from src/lib (forecast, progress, matching)
  supabase/
    migrations/ SQL schema, RLS policies, triggers
    functions/  Edge Functions (approve, reject, invite, index-login)
    seed.sql    subjects; local test users
    tests/      pgTAP tests for RLS
```

- npm workspaces. No Turborepo until build times justify it.
- `apps/web` keeps the Next.js version in use (16.x). Its `AGENTS.md` rule applies: read `node_modules/next/dist/docs/` before writing Next code.
- **Staff screens** (`/admin`, `/teacher`, `/tutor`, `/corrector`, `/owner`) live in `apps/web` only. The desktop app is a thin shell over them, so staff screens are built once. Staff can also use them in a normal browser.
- **Student and parent screens** are rebuilt in `apps/mobile`. The existing web student/parent pages stay in `apps/web` as a fallback until Part 4 is done, then are removed.
- Every app talks to Supabase directly with the user's session (anon key + RLS). Privileged actions go through Edge Functions. No app ships the service-role key.

## 5. Roles and permissions

| Role | Sees and does |
|---|---|
| owner | Everything, incl. payments, staff management, owner reports. Only role that can invite or remove admins. |
| admin | Approvals, student records, timetable, notices, paper allocation. Invites teachers, tutors, correctors. |
| teacher | Only assigned subjects: sets exams, sees those subjects' results. |
| tutor | Only assigned students: read-only progress. |
| corrector | Only papers allocated to them; sees index numbers, not names. |
| student | Own data only. |
| parent | Own account and linked children's data only. |

In Part 1 only these permissions are live: owner/admin manage accounts and approvals; everyone reads their own profile; parents read linked children's profiles; tutors read assigned students' profiles; teachers see nothing yet (subjects only matter from Part 2); correctors see nothing yet (Part 3).

## 6. Account lifecycle

### 6.1 Student self sign-up (mobile app, and web fallback)

Form: first name, last name, email (no password), date of birth, school, parent name, parent email, agree to terms.

1. The form calls the public `register-student` Edge Function (not `auth.signUp`). It validates the fields, rate limits (30 per IP and 3 per email per 15 minutes, before any lookup), and creates the unconfirmed Auth user WITHOUT a password, then emails a recovery link (valid 1 hour) that confirms the address and sends the person to choose their password, so whoever submits an address never holds a usable password for it. If an earlier, still unconfirmed self sign-up exists for the same email and is over 1 hour old it is deleted and replaced; a younger one is left alone. An address that is already confirmed (or belongs to any other kind of account), and a failed email send (the new account is removed), all get the same neutral answer: 200 `{ ok: true }` after at least 800 ms, so the form never reveals which addresses exist. The project setting "Allow new users to sign up" is turned OFF in the Supabase dashboard so `auth.signUp` cannot bypass the function.
2. A trigger on `auth.users` insert creates `profiles` (role `student`, status `unconfirmed`) and `student_details`. The trigger **ignores any role or status sent in sign-up metadata**; only the listed form fields are copied.
3. When the email is confirmed (trigger on `auth.users` update when `email_confirmed_at` becomes set), status becomes `pending` and the registration appears in the admin approval list.
4. Sign-ups still `unconfirmed` after 7 days are deleted by a daily scheduled job (pg_cron), with the same audit row as a rejection but action `registration_expired`.

Status values: `unconfirmed` → `pending` → `profile_incomplete` → `active`, plus `suspended`.

| Status | What the student sees after signing in |
|---|---|
| unconfirmed | "Check your email to confirm your address" + resend link |
| pending | "Awaiting approval" |
| profile_incomplete | Profile form only |
| active | Full app |
| suspended | "Your account is suspended, contact the institution" |

### 6.2 Approval (admin or owner, `approve-student` Edge Function)

In one database transaction:
1. Check caller is admin or owner and the student is `pending`.
2. Assign the next index number (`SE-<year of approval>-<4-digit sequence>`, e.g. `SE-2026-0142`; unique constraint; sequence restarts each calendar year).
3. Set status `profile_incomplete`.
4. Find or create the parent: if an account with the parent email exists and is a parent, link the child; if it exists with any other role, fail with a clear message; otherwise create a parent invite.
5. Write audit rows.

After the transaction: send the student an approval email (with index number) and the parent an invite email. Email failure does not undo approval; the student record shows "invite not sent" with a Resend button.

### 6.3 Rejection (admin or owner, `reject-student` Edge Function)

1. Check caller role and that the student is `pending` (approved students cannot be rejected; use suspend).
2. Send the rejection email first (address is needed), then delete the auth user; `profiles`, `student_details` and `student_subjects` cascade.
3. Write one audit row: actor, action `registration_rejected`, timestamp, no target id and no personal data.

The same email can register again afterwards.

### 6.4 Profile completion (student)

Fields: gender, year group, subjects (from `subjects`), parent phone, optional photo. Submitting valid data sets status `active` (done by a database function so the student cannot set other statuses).

### 6.5 Staff and parent invites (`invite-user` Edge Function)

- Owner can invite any staff role; admin can invite teacher, tutor, corrector.
- Creates the auth user with Supabase invite email; the profile is created with the given role and status `active`.
- Staff cannot self sign-up; the web sign-up page only creates students.
- An email can hold only one account and one role.

### 6.6 First owner

Created once by a setup script (`npm run setup:owner -- <email>`) run against the project with the service key from the developer's machine.

### 6.7 Login

- Email + password for everyone, via Supabase Auth.
- Students may use index number + password through the `index-login` Edge Function: it looks up the email server side, signs in, and returns only the session. It never returns the email. Failures always return the same generic error. Rate limited per IP and per index number (5 attempts per 15 minutes).
- Password reset: Supabase reset email.
- After login each app routes by role. The mobile app only accepts student and parent roles (others see "use the desktop app"); the staff area only accepts staff roles.

### 6.8 Account deletion

Apple requires in-app account deletion. Students and parents get "Delete my account" in the mobile app settings: it deletes the auth user (cascade) and writes an audit row without personal data. A parent cannot delete a child's account in Part 1.

### 6.9 Parents adding children (owner decision, 2026-11-07)

Every child goes through the same protocol, whoever starts it. A parent never sees a child before an admin approves.

- **Register a child (parent-initiated):** the parent, signed in, submits the same fields as §6.1 for the child, including an email for the child but NO password (owner decision 2026-11-07: the child sets their own password; the parent can never sign in as the child). The child receives one email link that confirms the address and sets the password. The child's account is created exactly as a self sign-up: confirmation email to the child's address, `unconfirmed` → `pending` → admin approval → `profile_incomplete` → `active`; admin may reject (deleted as §6.3). The registration records `requested_by_parent = <parent id>`; on approval the child is linked to that parent (and to any parent matching `signup_parent_email`). `signup_parent_email` is set to the requesting parent's email.
- **Link an existing child:** the parent submits the child's index number + date of birth. A wrong combination returns the same generic "We could not find a child with those details" and counts toward a rate limit (5 per 15 minutes per parent and per index number). A correct combination creates a `parent_link_requests` row (`pending`), never a link. Owner/admin approve (creates the `parent_children` row) or reject (row deleted). Audit rows for request, approval and rejection carry ids only.
- A child may have several linked parents/guardians.
- Admin approval list shows parent-initiated registrations and link requests alongside self sign-ups.

## 7. Data model (Part 1)

```
profiles          id (= auth.users.id) PK, role, status, first_name, last_name,
                  email UNIQUE, invite_sent_at, created_at
student_details   profile_id PK FK profiles ON DELETE CASCADE, date_of_birth, school,
                  gender, year_group, index_number UNIQUE NULL,
                  signup_parent_name, signup_parent_email, parent_phone, photo_path
subjects          id PK, name UNIQUE, kind ('school' | 'entrance'), active
student_subjects  student_id FK, subject_id FK, PK(student_id, subject_id)
parent_children   parent_id FK, student_id FK, PK(parent_id, student_id)
teacher_subjects  teacher_id FK, subject_id FK, PK(...)
tutor_students    tutor_id FK, student_id FK, PK(...)
audit_log         id PK, actor_id NULL, action, target_type NULL, target_id NULL, created_at
```

- `role` and `status` are Postgres enums.
- `signup_parent_*` is a snapshot of what the student typed; after approval the parent account is the source of truth.
- Seed subjects: Maths, Further Maths, Physics, Chemistry, Biology, Computer Science (school); TMUA, FSAT, UCAT (entrance).
- Photos: private Storage bucket `student-photos`, path `<profile_id>/photo.jpg`, read only via signed URLs (60 s).

## 8. Security

- RLS enabled on every table, default deny. Policies:
  - `profiles`/`student_details`: self read; owner/admin read all; parent reads linked children; tutor reads assigned students. Self may update only profile-completion fields via the completion function.
  - `subjects`: everyone signed in reads; owner/admin write.
  - Link tables: owner/admin write; members read their own rows.
  - `audit_log`: insert only through server functions; owner/admin read; nobody updates or deletes.
- A trigger blocks any change to `role`, `status` or `index_number` unless it comes from the service role or the completion function.
- Edge Functions check the caller's role from the database, never from the JWT claims or request body.
- Data in Supabase London (eu-west-2). Card data never touches the system (Stripe-hosted checkout, Part 2).
- Students are minors (Year 10 and above, 14+). Only data needed for running exams is collected; privacy notice and terms pages are required before store submission (Part 5).

## 9. Apps in Part 1

### 9.1 Web (`apps/web`)

- Public site: existing home page and exam catalogue, unchanged.
- `/login`, `/register`, `/reset-password`: wired to Supabase, replacing the mock login role picker.
- Student status screens (6.1 table) as a web fallback. Students and parents can delete their own account from every `/account/*` page ("Delete my account", with confirmation). Parent "add a child" and "link a child" screens (6.9) arrive with the mobile app (Task 14); until then admins create the links.
- `/admin/accounts`: real data. Pending list with Approve/Reject (reject asks for confirmation), all accounts with filters by role and status, suspend/reactivate, resend invite, invite staff.
- `/owner`: same as admin plus invite/remove admins.
- Route protection by role in Next.js middleware/proxy (per the Next 16 docs) plus RLS as the real guard.
- Other existing mock pages stay as they are until their part.

### 9.2 Payments placement (affects Part 2)

Card payments happen on the web site only. The iOS app shows booking status but has no pay button, to stay within App Store rules on payments.

### 9.3 Staff on desktop computers (owner decision 2026-11-08: no desktop application)

Staff use the web app (`apps/web`) in a normal browser on their computers. There is no Tauri/desktop wrapper. The original desktop notes below are superseded.

#### (superseded) Desktop (`apps/desktop`)

- Tauri v2 window loading the hosted staff URL. Session lives in the webview.
- Part 1: builds and runs locally on Windows; signed installers and auto-update are Part 5.

### 9.4 Mobile (`apps/mobile`)

- Expo, expo-router, supabase-js with session stored in expo-secure-store.
- Platform-native look (owner decision, 2026-11-07): iPhone follows Apple's Human Interface Guidelines and Android follows Material 3. One codebase; navigation uses expo-router native stack/tabs; controls use `@expo/ui` (SwiftUI on iOS, Jetpack Compose on Android); platform icons (SF Symbols on iOS, Material Symbols on Android); platform alerts/sheets vs dialogs/snackbars. Screens share logic; where layout differs, use `.ios.tsx` / `.android.tsx` files.
- Screens: sign in (email or index number), register, forgot password, status screens, profile completion, a placeholder home ("Your dashboard is coming soon" plus name and index number), settings with sign out and delete account.
- Parent: sign in from invite, placeholder home listing linked children.
- Runs in Expo Go / development builds; store builds are Part 5.

## 10. Error handling

- Duplicate email at sign-up (and a failed confirmation email): the same neutral "check your email to confirm your address and choose your password" screen as a new sign-up, with the same status, body and minimum response time (privacy: the form never reveals which addresses have accounts). Someone who owns the address and already has an account can use Forgot password.
- Approve/reject on a student whose status changed meanwhile: function returns a conflict; UI refreshes the list and shows "This registration was already handled".
- Parent email belongs to a staff account: approval fails with that message; admin edits the parent email first.
- Email send failure: action still succeeds, record flagged, Resend button.
- Network failure in apps: retry button; forms keep entered data.
- All Edge Functions return `{ error: { code, message } }` with stable codes the apps map to messages.

## 11. Testing

- **RLS:** pgTAP tests run against local Supabase (`supabase test db`) for every role × table: allowed reads/writes succeed, others fail. Includes the role-escalation-at-sign-up case and audit log immutability.
- **Edge Functions:** Deno tests for approve, reject, invite, index-login (including rate limit and generic errors).
- **Shared logic:** Vitest for `packages/shared` (moved forecast/progress/matching code keeps its behaviour).
- **Web:** Playwright for register → confirm → approve → complete profile → active, and reject → record gone → can re-register.
- **Mobile:** manual test checklist on Android emulator and iOS simulator for Part 1 screens.
- CI (GitHub Actions): lint, type-check, Vitest, pgTAP, Playwright on each push.

## 12. Out of scope for Part 1

Exams, timetable, bookings, payments, attendance, papers, marking, results, reports, notices, push notifications, store submission, desktop installers. The existing mock pages for these remain visible but unchanged.

## 13. Costs and accounts the owner needs

- Supabase project (free tier is enough for Part 1; Pro, about $25/month, before real use for backups).
- Apple Developer Program (about £79/year) and Google Play developer account ($25 once) before Part 5.
- Stripe account before Part 2.
- A sending domain for email (e.g. via Resend or Supabase custom SMTP) so emails do not land in spam.
