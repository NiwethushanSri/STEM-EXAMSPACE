# Phase 1A: decisions taken during the build, and follow-ups

Branch `phase1-papers`, reviewed range `8578b38..9b4d050`. Every task had an independent review, the whole branch had a final review, and the final fix wave was re-checked clean. This file keeps the decisions made on the owner's behalf and the small items left for later, so they survive the build's temporary notes.

## Decisions made during the build (each with what it costs if wrong)

1. Tasks 1 and 2 were built as one step, because dropping the old seat columns before rewriting the booking functions would have broken bookings in between. Cost if wrong: one larger review.
2. Local database tests run SQL through `psql` in the database container, because the CLI's query command fails on multi-statement files. Cost: runner rework.
3. The local Supabase stack runs without studio, logs, realtime and image services, to fit this computer's memory. Cost: restart without the flags.
4. Local browser tests run against a production build, not the development server, which starved the machine. Cost: development-only errors are not caught there (visual checks run separately).
5. Removed centres are archived (`removed_at`), not deleted. Only live bookings block removal; past bookings keep their centre for history. Cost: one extra column and filters.
6. Closing a centre's register only closes that centre. Every exam is marked completed automatically 2 hours after its scheduled end. Cost: completion is 2 hours later than before for centre-only exams.
7. Task 3's browser tests ran at the end of Task 4, because the site could not build until Task 4. Cost: Task 3 issues surfaced one step later (none did).
8. Paper rules: reasons are stored in the audit log; families cannot change the release clock; moving an exam clears an early release and re-sends the release email; the paper section shows only for paid bookings (or with a cancellation request waiting); copy records are never deleted. Cost: none known.
9. The copy-building module was built while the paper database step was in review (separate files). Cost: none.
10. The bottom band is 92 pt so the QR code keeps its full clear margin and nothing prints within 12 pt of the edge; the exam page prints at about 85% of its size. Cost: content slightly smaller; confirm on paper in the owner trial.
11. Candidate names print as written when the font can show them; other letters are converted to the nearest plain letter (Ł → L). Non-Latin scripts print as "?"; the index number always prints exactly. Cost: non-Latin names are not shown.
12. The paper size limit is 20 MB (35 MB papers hit the server's time warning locally). Cost: admins must compress large scans.
13. Release emails: with email off, nothing is sent or recorded; each person is recorded before sending so nobody gets the same email twice; a failed exam is retried at 15 and 30 minutes, then given up. Cost: an email can be lost on a send failure after it was recorded.
14. The scheduler's connection waits up to 120 seconds for the email run. Cost: none known.
15. Booklet (insert) downloads are not logged; paper downloads are. Cost: no record of who downloaded a data booklet.
16. Parked: a replacement paper over 500 pages, uploaded before any copy exists, first shows the "give a reason" message instead of the 500-page message. Real but rare; fix next time the paper panel is touched.

## Before switching email on

- Spread the release-email retries over more of the window (for example 15, 45 and 120 minutes, not 15 and 30).
- Watch sending speed when two scheduler runs overlap (up to about 4 per second); confirm it is within the email provider's limit.

## Before or soon after 1 December

- Upgrade Next.js from 16.4.4 (its own tooling flags a known vulnerability) as a separate, tested step before deploying.
- Measure `paper-copy` on the hosted project with a 20 MB paper before the first home exam.
- Families can call the download log themselves (it only affects their own booking); log through the server with the actor passed in before Phase 2 relies on the log as evidence.
- Signed-in families can read room names through the API (no page shows them); restrict with a column grant or view.

## Can wait

- Tooling: env-file and project-id checks in the local test runner; duplicated env parsing; Node 20.11 requirement noted.
- Centres and bookings: moving a booking out of a closed register; from→to detail in the sitting-change audit; a published exam dropping its only open centre after another closed; extra test cases; the completion job running all exams in one transaction.
- Staff screens: unique names for "Remove centre" buttons, focus after adding or removing a centre, splitting the exam form.
- Booking screens: small code tidy-ups in the admin booking actions.
- Paper copies: extra rotation and rendered-QR tests; input checks in the copy builder; the readable code's "p" sits slightly under 12 pt from the edge.
- Admin paper page: a stuck progress state if the cover font fails; retrying a pack re-logs earlier copies.
- Family card: one request per booking on My bookings; "closed" shown on past bookings; polling continues while a paper is missing.
- Scan check: a failed chunk discards the chunks that succeeded; blank pages get three read attempts; no limit on the number of image files.
