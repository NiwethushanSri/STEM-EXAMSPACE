# Phase 3B release notes: checking the marking

Written 25 November 2026 for the owner. Nothing in this part has been deployed. Everything below was built and tested on the local test copy of the system only, with made-up scripts (see "Known limits").

Phase 3A let markers mark a script without seeing a name. Phase 3B checks that marking before any result can be made from it. A sample of each exam is marked again by a second marker who sees nothing of the first. Markers practise before live marking and meet seeded scripts they cannot tell from the rest. The lead marker settles differences, looks over each marker's work and sends work back. Admins see marker statistics, approve an exam's marking once every script is checked, set marker pay rates and download monthly statements. A script now ends at "Checked", and an exam's marking at "Approved". Below, a "piece" is a whole script, or one question group of a script when an exam is marked by question.

## What changed

### For markers (exam correctors, and teachers who mark)

- **Second marking looks like first marking.** A second marker presses "Next script" or opens an assigned script as usual. They see a clean page: none of the first marker's marks, ticks, total or note. Nothing on the screen says it is a second marking.
- **Practice first.** Before live marking on an exam, a marker marks the lead marker's practice scripts. Each one says "Practice" beside "Name hidden". After Submit they see their marks beside the lead marker's, with "Different" on each question outside the tolerance, both totals and the lead marker's note. When every practice script is done, the exam's card says "Your practice scripts are with the lead marker." and they wait for the lead marker to clear them. The card shows "Practice first: 1 of 3 done" until then.
- **Seeded scripts.** About one script in ten that "Next script" hands out is a seeded script: one the lead marker has already marked. It looks exactly like any other script, on the screen, in the list and in what the browser receives. Marked within the tolerance, nothing is said. Marked outside it, the marker is shown the lead marker's marks and that attempt is locked. Three misses in a row on one exam pause the marker on that exam.
- **Paused.** A paused marker's exam card says "Your marking on this exam is paused. The lead marker will be in touch." with no "Next script". A change to a submitted script is refused with the same sentence.
- **Sent back.** A script the lead marker sends back says "Sent back by the lead marker." in the marker's list, and "The lead marker sent this back: {note}" above the page. The marker changes their marks and submits again.
- **Settled.** Once the lead marker has settled a difference on a script, its markers can no longer change their marks on it: "The lead marker has settled this script. Ask them if a mark should change." The screen puts the saved marks back and never says "Saved" for a change that was refused.
- **Picture links are made on the server** after the database checks who is asking. A marker can no longer make a long-lived link to a marking picture themselves. The links still expire after 120 seconds.
- **The screen's access check** now runs every 15 seconds and is due 55 seconds after the last, so a page taken away leaves the screen within about a minute.

### For lead markers

- **Review** (/marking/review, under "Marking" in the menu). Tabs: "Marks that differ", "Paused markers' scripts", "Your sample", "Markers", "Practice and seeded scripts" and "Statistics". Each list shows the script number, the index number, both markers and their totals. A script the lead marked themselves says "You marked this script."
- **The review screen** shows the pages with a switch between "First marker's marks", "Second marker's marks" and "No marks", a table of each question's marks with "Different" where they differ by more than the tolerance, both totals, and each marker's private note.
  - On marks that differ: "First marks stand", "Second marks stand" or "Set my own marks", each with a reason. The script is then "Checked".
  - On a paused marker's script, or a script of the lead's sample: "Accept", "Change a final mark" (with a reason) and "Send back". Send back goes "To the same marker", with a note they read on the script, or "To another marker".
  - If a marker changed the script while the lead was looking, the screen says so and asks the lead to reload. Nothing is settled on marks the lead did not see.
- **Markers** tab: each marker's practice and clearance, misses in a row, "Clear for live marking", "Pause" and "Review 5 of their scripts" (the routine sample, which never holds a script back).
- **Practice and seeded scripts** tab: the lead marks a script as any marker does, then presses "Use for practice" or "Use as a seeded script", with an optional note on why. The marks are copied and kept as they are. Each one shows its attempts and how many were outside the tolerance. "Stop using" (with a reason) ends one.
- **Stuck scripts.** When scripts wait for a second marker and nobody can take them (for example the only other marker has a declared conflict), the Review page says so: "{n} scripts wait for a second marker and nobody can take them. Ask an admin to assign one or release them on the Marking page."
- **Progress** on /marking now says, per exam, "12 checked · 3 with the lead marker · 2 waiting for a second marker".
- **Statistics**: per marker, scripts marked, their average mark against the other markers' on the same question groups, agreement with second markers, with seeded and practice scripts, usual time per script and how often their work was sent back. From 10 scripts, a neutral note headed "Worth a look" may appear. These are a prompt to look, never a finding.
- **Menus**: a lead marker sees "Review" under "Marking" on every page of their area.

### For admins

- **Checks on the marking** (on the exam page, under Marking): "Double marking" with "Second-mark {n}% of scripts" (10% unless changed) and "Send to the lead marker when marks differ by more than {n}% of the maximum" (10%, at least one mark); "Seeded scripts" with "About one in every {n} scripts" (10); "Practice before live marking". All three are on by default. They can be turned off, with a reason, only while the subject has at most one approved marker (the lead marker counts as one). Opening marking with double marking on needs two approved markers; with seeds or practice on, it needs a lead marker. Once marking has opened, any change needs a reason.
- **The Marking page** (/admin/marking): each script shows its check ("Waiting for a second marker", "With the lead marker", "Checked") and its second marker. New actions: "Second-mark these", "Release from second marking" (with a reason), "Assign second marking to…" and "Take back second marking". Each exam links to its review, its marker statistics and its approval.
- **Approval** (/admin/marking/{exam}/approval): the scripts checked, withdrawn and void, candidates with no script, what still blocks approval in one sentence each, the checks in words (and, when any was turned off, "Checks turned off" with the reason, who and when), and what the checks found. "Approve this exam's marking" (with an optional note) closes marking and freezes it: marks, final marks, questions and checks stay as they are until an admin presses "Withdraw approval" with a reason. A script that arrives or changes after the approval is flagged: "A script arrived or changed after this approval. Withdraw the approval to include it." It is never added silently.
- **Marker pay**: on the exam page, "Pay per script" (or one box per question group for an exam marked by question), in pounds. First and second marking are paid at the same rate. Practice and seeded scripts are never paid.
- **Marker payments** (/admin/marking/payments): a month picker (UK months), each marker's lines and total, "Fix this month's statements" once the month has ended, and "Download CSV". A fixed statement never changes; marking it missed is carried into the next month. Paying markers happens outside the system.
- **Admin home page**: each exam's marking row also shows "Checked", "With the lead marker", "Waiting for a second marker" and an "Approved" badge. New alerts, the most urgent first:
  - "A script arrived after the marking of {n} exams was approved."
  - "{n} scripts wait for a second marker and nobody can take them."
  - "{n} scripts wait for the lead marker."
  - "{n} markers are paused."
  - "{n} exams are ready for their marking to be approved."
  "On hold in marking" and the open alerts now count scripts, not pieces: a script marked by question with three pieces on hold counts once.
- **The last demonstration pages are gone**: /examiner and /examiner/standardisation now show "page not found", and the menu entry is removed.
- **One email**, to the lead marker and admins, when a marker is paused after three seeded scripts outside the tolerance. It names neither the marker nor any candidate.

## Calls for you to confirm or change

The full table is in docs/superpowers/plans/2026-11-23-phase3b-checking.md ("Builder's calls in this plan"). Please look above all at 2, 5, 9, 10, 17 and 18. You approved the plan without answering its five questions, so these defaults stand (Ruling R1); each costs a small change if you decide otherwise:

1. **Second marking is paid at the first-marking rate, and the lead's review work is not paid** (call 17).
2. **No pay for work taken away** (call 17): a marking set aside (taken back, sent to another marker, name seen) is not paid. You settle such cases outside the system.
3. **Markers see no statements and no statistics** (calls 16 and 18). Statements and the CSV are for admins.
4. **The checks can be switched off only while the subject has at most one approved marker** (call 10). A two-marker subject where one falls ill must first remove that marker's approval.
5. **The lead marker clears each marker after practice by hand**, with a reason, whatever their marks (call 9).

Also from the plan's table:

- **The sample is drawn per piece, not per script** (call 2), so a small exam may get no second marking by chance (10% of 8 is often none). The approval page shows how many were second-marked.
- **A practice or seeded script is a copy of the lead marker's own marking** (call 5), and that piece is not itself second-marked.

## Open questions for you

- **Index number on the marking screen** (Phase 3A, Ruling R4): markers see the index number, as the design says. If you prefer "script number only", it is one field to hide.
- **The five defaults above** (Ruling R1): do they stand?
- **Should a lead marker be able to release or assign scripts stuck waiting for a second marker?** Today only an admin can, from the Marking page (Ruling R18). It would be a new list for the lead.
- **Marker statistics compare each marker with all markers, themselves included** (Ruling R20). A marker who marked most of a group's scripts pulls the group's average towards their own, so "Average mark is far from the other markers'" may show less often for them than it should. Leaving them out of their own comparison is a small change.

## Deploy order

Do not deploy until you give the go-ahead.

**Before you start**

- **Deploy the phases in order, each on your go-ahead: Phase 1A, then Phase 2, then Phase 3A, then Phase 3B.** Each has its own release notes (docs/superpowers/2026-11-18-phase1a-release-notes.md, 2026-11-21-phase2-release-notes.md, 2026-11-22-phase3a-release-notes.md). Phase 3B is built on all three.
- **Take a backup, or confirm point-in-time recovery is on,** for the live database.
- **Pick a time with no exam running and no marking open.**
- **Never run `supabase config push` from this repository.** Its settings point sign-in links at the local test copy.
- **Gate: the browser tests must pass on the final version.** They have not been run on this part's final version (see "How it was tested"). Run `npm run e2e:local -w @stem/web` once, on a machine with port 3005 free and at least 3 GB of memory free. It builds the site, starts its own copy, the processing server and the Edge Functions, and runs every browser test, the four marking ones included (marking.spec.ts, marking-admin.spec.ts, marking-checks.spec.ts and the new marking-checks-admin.spec.ts). Do not deploy until it passes.
- **Gate: the website build.** It was not run on this part's final version either (too little memory was free). The full browser run above builds it. Every build still stops once on Next.js's security notice; a second run then builds. Upgrading Next.js is its own, tested step, done only with your go-ahead.
- **Gate: a real iPad with an Apple Pencil**, as in Phase 3A (owner action below), now also on a second marking and a practice script.

**Steps**

1. **Migrations 20261123000001 to 20261123000011**, after Phase 3A's 20261122000001 to 20261122000015 (`npm run db:push`, by your go-ahead only). 001 is Phase 3A's carry-overs; 002 signs picture links on the server and removes the markers' own access to the picture store; 003 adds the tables and settings for the checks; 004 hands out second markings; 005 is the check itself, the "Checked" state and final marks; 006 adds practice, seeded scripts and the pause; 007 the lead's review; 008 the marker statistics; 009 approval; 010 marker pay; 011 the dashboard figures and alerts. No new scheduled job: `marking-tick` (every minute) also applies pauses now.
2. **Edge Functions: deploy the new `marking-pictures` and redeploy `script-notify`.** The shared email code changed too (the "marker paused" email was added), so deploy every function with `npm run fn:deploy`. No new secret is needed.
3. **The website.**

Migration 002, `marking-pictures` and the website must go live together, one straight after the other: after 002 the old website can no longer show marking pictures, and the new website needs the new function.

The processing server did not change in this part.

**Check afterwards**

- **A marker opens a script and its pictures show** (the links now come from `marking-pictures`).
- **A marker cannot make a link themselves**: in the SQL editor, `select policyname from pg_policies where tablename = 'objects' and policyname = 'script_pages_objects_select_marker';` returns no row.
- **A test exam goes from second marking to "Checked" to approved**: with double marking at 100% on a test exam with two test markers and a test lead marker, mark a test script, second-mark it with other marks, settle it on the Review page, and see it "Checked"; then approve the exam's marking and see "Approved by…".
- `select rolconfig from pg_roles where rolname in ('authenticated', 'service_role');` still shows `statement_timeout=8s` and `statement_timeout=5min`.

## Owner actions

1. **For each exam, set the sample and the tolerance** under "Checks on the marking" (10% and 10% unless you change them), and turn off what a one-marker subject cannot have, with a reason.
2. **Choose a lead marker for each subject** (/admin/marking/markers).
3. **Ask each lead marker, before markers start, to mark a few scripts and choose the practice and seeded scripts** from them (Review, "Practice and seeded scripts"). Without practice scripts, markers on an exam with practice on cannot start until the lead clears them.
4. **Set the pay rates** on each exam's page, under "Marker pay". A month's statements cannot be fixed while any of its marking has no rate.
5. **Decide the calls and questions above**, above all calls 2, 5, 9, 10, 17 and 18.
6. **Before any deploy: the full browser run, the website build and the real iPad check** (the gates under "Before you start"). These are not follow-ups: the deploy waits for them.
7. **The Next.js upgrade**, as its own step.

## How it was tested

On the local test copy only, on 25 November 2026, one suite at a time:

- Database tests: 63 files and 4,539 checks, all passing (11 files new in this part, 053 to 063), the timing tests included.
- Edge Function tests: 196 passed, 1 skipped, with the local functions server running.
- Processing server tests: 168 passed (it did not change).
- Website tests: 582 passed; shared code tests: 219 passed; type checks clean; the linter clean (3 old warnings).
- Browser tests: **not run on the final version**, because too little memory was free on this computer (about 0.4 to 0.7 GB; they need at least 2 GB, and the full run 3 GB). The marking browser tests last ran in Task 6 of this part (the marker's screens: 5 of 5; the Phase 3A marking tests: 11 of 11 and 8 of 8). The new staff test (marking-checks-admin.spec.ts) and the checks Task 13 added to marking-checks.spec.ts (a script sent back, a change to a settled script refused, a first look at the Review pages and the admin's check column) have never run. The new staff pages (Review, statistics, approval, payments) have not been seen in a browser.
- The website build: not run on the final version (memory, as above).
- Timed with large made-up exams: hand-out and the marker's list as in Phase 3A; marker statistics at 1,500 second-marked pieces about 0.1 seconds; the approval page at 1,500 second-marked scripts with 300 pictures to check about half a second; statements at 3,000 markings well under a second to read and to fix.

## Known limits

- **Seeded scripts come through "Next script" only.** A marker who works only on assigned scripts meets none.
- **A small exam may have no second marking by chance** (the sample is drawn per piece; see the calls above).
- **Markers have no payments page.** Statements and the CSV are for admins.
- **No email for a difference or a sample review.** The lead's Review page and the admin home page show them. The only new email is the one when a marker is paused.
- **Statistics are per piece, never per script,** and they include each marker in their own comparison (see the open questions).
- **A script withdrawn and then brought back after the exam's marking was approved is not flagged** when it comes back checked with its old final marks: the approval does not show as changed.
- **A seeded script whose hold ran out comes back to the same marker** through "Next script". It is a weak tell; nothing on the screen says so.
- **The timing tests are sensitive to memory on this computer.** Two of them (the hand-out test from Phase 3A and the check test from this part) failed in some full runs during this part while very little memory was free, and passed when run alone. None failed in the final full run, and no limit was loosened for this.
- **The full browser run, the website build and a real iPad check still gate the deploy** (see "Before you start").

### For the final review

These were found during this part and left for the review of the whole branch:

- How the timing tests should run here: with more memory free, in a separate pass, or with limits loosened as earlier rulings did.
- The "stuck" count can include a reviewed script whose second marking the lead already holds and can still submit.
- A lead marker replaced later could still be offered the second marking of a script they reviewed.
- A submitted seeded attempt on a script whose pages later changed is not flagged.
- The Review page's list and the review screen can show a different second marking for an open sample review.

## Where Phase 4 plugs in

- Results read `public.script_final_marks(script)` and `public.script_final_total(script)` and nothing else. They never add piece totals: a piece's total applies "answer 2 of these" inside the piece only.
- **Results may be prepared only while the exam's marking is approved, and never while the approval is stale** (a script arrived or changed after it: `marking_approval_get` says `stale`). Phase 4 must refuse to prepare results in that case (Ruling R22).
- Phase 4 must refuse `marking_approval_withdraw` once results are published.
- The annotated script a family sees is the marking named by `marking_units.final_marking_id`.
- A family re-mark is a `remark` marking; the hand-out rule and the pay rule already list it.

## Not in this part

- Results, grade boundaries, ranks and publishing (Phase 4); family re-marks.
- A comments library, audio feedback, offline marking and AI suggestions (Phase 5).
- Paying markers online: paying happens outside the system.
- **The family card payment gateway (Stripe) stays the last build** (your note of 25 November). The marker pay in this part is not the gateway.
- The Next.js upgrade (a separate step, with your go-ahead).
