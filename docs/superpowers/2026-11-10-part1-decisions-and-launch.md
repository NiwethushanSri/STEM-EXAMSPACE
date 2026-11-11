# Stem Examspace Part 1 — decisions, open risks and launch checklist

Date: 2026-11-10. Covers Part 1 (Foundation), commits c95c6a8..f06723f on `main`.
Spec: `specs/2026-11-07-crm-foundation-design.md`. Plan: `plans/2026-11-07-crm-foundation.md`.

## 1. What Part 1 delivers

- Supabase database (24+ migrations): profiles, student details, subjects, parent/tutor/teacher links, audit log, index numbers, invites, link requests, login attempt limits; row-level security on every table; all writes through checked server functions.
- Server functions: register-student, approve-student, reject-student, index-login, invite-user, account-admin (resend invite, suspend, reactivate, remove staff, delete account, clear stuck invite, edit parent email), delete-my-account, parent-child (register child, link request, approve/reject link).
- Website: public site, login (email or index number), registration, email confirmation, password set/reset, account status screens, profile completion with photo, delete my account, live admin and Super administrator account screens.
- Vercel project `stem-examspace` (team-only), GitHub checks on every push, manual full test run.
- Not built (owner decisions): mobile app (deferred), desktop app (dropped — staff use the browser).

## 2. Owner decisions

1. Roles: Super administrator (role `owner`, exactly one), admin, teacher, tutor, exam corrector, student, parent. Only the Super administrator adds or removes admins.
2. Parents have their own login and see only their linked children.
3. Public site kept; payments online via Stripe on the website only (Part 2).
4. Rejected registrations are deleted immediately.
5. Short sign-up; profile completed after approval.
6. Every child follows the same protocol, whoever starts it. Parents may register a child or request a link to an existing child (index number + date of birth); an admin approves every link. A child may have several parents/guardians.
7. A child registered by a parent sets their own password; the parent can never sign in as the child.
8. Mobile app: iPhone style on iPhone, Android style on Android, one Expo codebase — deferred to later.
9. No desktop application; staff use the website in a browser.
10. Supabase project `jmhjahwfskhlgagaqlrz` becomes the live project. Testing continues on it until Part 1 is finished; before launch it gets one clean rebuild and testing moves to a new separate project.
11. Website hosted on Vercel; first deploy's public alias removed — team-only until launch.
12. Function email (Resend) set up later.

## 3. Decisions taken on the owner's behalf (each with the cost if wrong)

Data and security model
- All writes go through definer SQL functions or server functions; clients only read, filtered by row-level security. — Cost: an admin "edit" UI always needs a server action (planned anyway).
- New tables/functions start closed (no access) and are opened one by one. — Cost: an extra grant line per object.
- The role-change lock checks the database account making the change, not a setting a user could alter. — Cost: none found.
- Invites carry a server-only secret code; an ordinary sign-up can never take an invite. Because Supabase attaches that code a moment after creating the account, a server step converts the new account immediately after creation, bound to that exact account and code. — Cost: more moving parts in invites (heavily tested).
- Invite writes are idempotent; two different roles for one email are refused. — Cost: a clash needs "clear stuck invite" first.
- Removed parent links are remembered and never re-created automatically; only an admin can re-link. — Cost: an admin must re-link by hand if a removal was a mistake.
- Children are never auto-linked to a suspended parent. — Cost: link after reactivation via "Resend parent invite".
- Exactly one Super administrator enforced by the database. — Cost: a second owner needs a schema change.
- Students and parents are suspended by status only (they can still sign in to see the "suspended" screen and delete their account); staff are also blocked from signing in. — Cost: a suspended learner's session keeps refreshing, but every data path refuses them.
- Suspended staff see "Email or password is incorrect." (no hint the account exists).
- Approval, rejection and all account changes write their audit row in the same step as the change; audit rows for rejections, expiry and deletions contain no personal data.
- Index numbers: `SE-<year>-<4+ digits>`, year in UTC, sequence restarts each year, never truncated above 9,999.
- Unconfirmed sign-ups deleted after 7 days by a nightly job at 03:00.
- Student sign-up runs on the server and takes no password: the emailed recovery link confirms the address and the inbox owner chooses the password. An unconfirmed sign-up with the same email is replaced only once creation and the last confirmation or recovery link are all over 1 hour old; younger, confirmed or protected accounts are never touched; public Supabase sign-up is off. (R1 fixed.)
- Registration always answers the same 200 `{ ok: true }` (new, replaced, protected, already confirmed, email not sent) after a fixed 800 ms (the slow work runs in the background, so timing does not depend on the case); 400 and 429 stay unpadded. (R2 fixed.)
- Set-password page: 8 to 72 characters, with a clear message for weak or breached passwords instead of "Something went wrong". (R3 fixed.)
- Registration limits: 30 per internet address and 3 per email per 15 minutes, both before any lookup (`login_attempt_begin_n`); index-number login keeps 5 / 5. (R4 fixed.)
- The "Awaiting approval" screen shows the parent email on record with "Not right? Contact the institution."; "Resend confirmation email" sends a recovery link.
- Function email fails closed: no email method configured → reported as not sent.

Logins and limits
- Index-number login: 5 failed attempts per 15 minutes per index number and per internet address, counted atomically; only genuinely wrong passwords count; failures padded to 600 ms. — Cost: see launch item L5 (shared Wi-Fi).
- All emailed links point to `/auth/callback?token_hash=…`, state they work for 1 hour, and send password-setting links to the set-password page even if the link is edited.
- Password minimum 8; secure password change on.

Photos
- Private bucket, JPEG only, up to 5 MB, path `<user id>/photo.jpg`; only students in profile completion or active can upload; deleted with the account, on rejection and on staff removal. — Cost: the mobile app must convert iPhone photos to JPEG.

Web and tooling
- Hosted Supabase dev project instead of local Docker; pgTAP tests run through a Docker-free runner that refuses test files containing COMMIT.
- Dev website on port 3005.
- Staff pages check role and status in the data loaders, not only the page frame; old mock-up pages with fake student/parent data are unreachable; other mock admin pages show "Preview — sample data".
- GitHub: quick checks on every push (no secrets); full tests started by hand, secrets only in a `integration` environment limited to `main`, given only to the steps that need them.
- Lint rules relaxed for 15 legacy mock-up files that Parts 2–4 replace.

## 4. Open risks

R1 to R4 (newest sign-up wins, registration existence oracle, password-policy messages, registration limit) are fixed and listed under Decisions. Residual risks:

- Someone can register an inbox owner's address with details of their choosing. Mitigations: the confirmation email and the pending screen both show the registered details, the inbox owner can ignore the email, and an admin approves every account.
- The per-email limit (3 in 15 minutes) can be used to delay a target's own registration. No data is exposed by this.
- The per-IP key trusts the gateway's `x-forwarded-for` header.
- Because registration always answers "check your email", an internal failure (database or email outage) also shows success; the person simply gets no email and can register again. Failures are logged by code.
- The registered details (typed by whoever submitted the form) appear in the confirmation email sent to the inbox owner. They are HTML-escaped and length-limited, but a mail client may turn text that looks like a web address into a link.
- Anyone can extend the 1-hour protection of an unconfirmed sign-up by triggering a new link to that address (bounded by Supabase's own email limits). The inbox owner can still complete their link.

## 5. Parked (waiting on something)

- 12 email tests fail until function email (Resend) is configured — they confirm the fail-closed fix works.
- The real sign-up → confirm → approve → complete run with real email must pass once Resend exists.
- Mobile app (Task 14).

## 6. Launch checklist

L1. Create a separate test project; repoint `.env.dev.local`, the CLI link and GitHub's `integration` environment to it; update the test guards that currently allow the live project (they clear rate-limit rows); remove or guard `db:reset`.
L2. Clean rebuild of `jmhjahwfskhlgagaqlrz` (`db reset --remote`); confirm auth users, photos and audit log are empty and the nightly job exists.
L3. Resend on your own domain (SPF/DKIM/DMARC); function secrets `EMAIL_PROVIDER=resend`, `RESEND_API_KEY`, `EMAIL_FROM`, `SITE_URL=https://<live domain>`; redeploy functions; send one of each email.
L4. Supabase dashboard for the live project: real SMTP on the same domain; token_hash templates; Site URL and redirects = live domain only (remove localhost); public sign-up off; phone sign-in off; leaked-password protection on; minimum password 8; secure password change on; email links expire after 1 hour; raise sign-in and email limits.
L5. Decide the shared Wi-Fi login limit (registration is now 30 per internet address and 3 per email; index-number login is still 5 per internet address).
L6. Rework the Super administrator setup guard (it currently refuses the dev project, which becomes live), then invite the Super administrator once.
L7. Supabase Pro (backups); privacy notice and terms pages linked from registration; data-processing agreements with email providers.
L8. Vercel: live domain; preview deployments must not point at the live database; review deployment protection.
L9. GitHub: repository owner creates the `integration` environment (main only) with the test project's secrets and deletes any repository-level copies.

## 7. Part 2 additions (exams and bookings, before the payment gateway)

Delivered stages 1–5 of `specs/2026-11-10-part2-exams-bookings-design.md` §9: venues and exams, bookings with offline payment, cancellations and recorded refunds, finance totals, attendance with QR/typed index numbers, index cards, and teacher/tutor/corrector home pages. Migrations 0029–0042.

Decisions taken on the owner's behalf (cost if wrong):
- Unpaid bookings hold a seat until the booking deadline; a family can have at most 3 unpaid bookings and can cancel an unpaid one itself. — A large family must pay before booking a fourth.
- Deleting an account releases only bookings on upcoming published exams (paid ones are flagged for refund); bookings on exams already sat stay for the records, anonymised.
- An admin can add an unpaid booking only before the booking deadline; after it, only as paid.
- Attendance: "booked" means paid or cancellation requested; present before start + 15 minutes, late after; closing the register marks the rest absent, releases leftover unpaid bookings and completes the exam.
- Teachers looking up an index number for a student not booked on that exam see only "No paid booking" (no name or photo).
- Teachers see "Photo unavailable" and no names in register lists; only admins can open student photos (owner decision pending).
- Index cards: the student and owner/admin only; the QR holds the index number only.
- Finance counts money by the London month it was paid (`paid_at`); refunds are shown against that month. Default range is the academic year 1 Sep – 31 Aug.
- Booking notes are visible to the family (the note box says so).

Launch checklist additions:
L10. Confirm both scheduled jobs exist on the live project after the clean rebuild: `expire-unpaid-bookings` (every 5 minutes) and the nightly unconfirmed sign-up clean-up.
L11. Stripe (Part 2 stage 6) is not built yet: the owner creates a Stripe account (test mode first) and sets `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` as function secrets; webhook endpoint `<SUPABASE_URL>/functions/v1/stripe-webhook`. Live mode only after this checklist.
L12. The dev `paid_at` backfill is an estimate; the clean rebuild (L2) removes it.
- 2026-11-11 (owner decision): the site was made public again at https://stem-examspace.vercel.app (production build of commit a7989bd), still running on the live Supabase project with test data and with function email off. Earlier decision 11 ("team-only until launch") is replaced.
- 2026-11-11 (owner decision): Niwethushan Sritharan was made the Super administrator on `jmhjahwfskhlgagaqlrz` (account created by the owner in the Supabase dashboard, then promoted from the default student shell; audit row `owner_set_up`). The test suites refuse to run while a real owner exists, so launch item L1 (separate test project) must be done before more testing.
