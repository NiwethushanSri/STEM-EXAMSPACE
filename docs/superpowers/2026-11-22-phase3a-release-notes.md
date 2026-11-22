# Phase 3A release notes: marking a script

Written 22 November 2026 for the owner. Nothing in this part has been deployed. Everything below was built and tested on the local test copy of the system only, with made-up scripts (see "Known limits").

Phase 3A is the heart of the system: staff enter each exam's questions and mark scheme, approve markers and open marking, and markers mark verified scripts on a computer or an iPad with Apple Pencil, without ever seeing a candidate's name. They save as they work and submit when every question has a mark. Admins assign scripts, take them back and see what is left. In this part a script ends at "marked": the checks after marking (double marking, review, approval) come in Phase 3B.

## What changed

### For markers (exam correctors, and teachers who mark)

- **Marking** (/marking) is the marker's home page. An account that is not approved yet sees "You are not approved to mark yet. Ask an admin." Otherwise each open exam has a card with its deadline ("Mark by 12 December, 17:00", and "Overdue" in red once it has passed), "{n} left to mark" and **"Next script"**. An exam marked by question has one "Next script" per question group. When nothing is free the page says "Nothing left to mark for now."
- **Next script** hands out a free, verified script at random and holds it for that marker for **2 hours**. Every save renews the hold. Two markers pressing it at the same moment never get the same script.
- **Your scripts** lists what the marker holds or has submitted: the script number, the index number, "In progress", "Submitted" or "On hold", and the hold line ("Held for you until 14:35", "Assigned to you" or "Hold ended"). "Open" goes back to a script and "Give back" returns it for others (a reason is optional). A script whose pages changed while it was with staff says "Pages of this script changed. Check your marks and submit again."
- **The marking screen** fills the whole screen:
  - The header shows the exam, the index number, a "Name hidden" pill, the save status ("Saved", "Saving…", or "Not saved: no connection. Your work is kept on this screen and will be sent when you are back online."), the hold line, and "Name visible", "Give back" and "Submit".
  - On a wide screen (1,200 px and more) there are three areas: the questions with their marks so far, "NR" or a dash, the running total ("17 / 60") and the page thumbnails on the left; one page at a time in the middle; the mark panel on the right. From 600 to 1,199 px the questions open from a "Questions" button. On a phone (under 600 px) the screen says only "Marking needs a computer or an iPad."
  - The mark panel shows the question's maximum, its marking points, acceptable alternatives and guidance, the mark buttons (with a number box beside them for a question out of more than 9, and only the box when there would be more than 21 buttons), "+½" when half marks are allowed, and "NR" (no response, which is recorded as an answer, not as a zero). "Open the mark scheme PDF" opens the attached file. "Private note to the lead marker" is never shown to families; the screen says that notes written on the page are.
  - The tools: select, tick, cross, 15 more stamps (BOD, ECF, SEEN and the others), pen, highlighter, text note, ruler, eraser, undo, redo and zoom (50% to 400%).
  - Keyboard: a digit gives the mark (for a question out of more than 9 it goes to the number box and replaces what is there), Enter moves to the next question, N is NR, T tick, X cross, P pen, H highlighter, C text note, R ruler, E eraser, the arrow keys move between questions and pages, Ctrl+Z undoes. Shortcuts are off while typing in a box.
  - **iPad with Apple Pencil:** the Pencil writes; one finger scrolls and two fingers zoom, whatever tool is chosen; a palm resting on the screen while the Pencil writes (and for half a second after) is ignored. "Draw with finger" is for an iPad without a Pencil.
  - Work is saved about a second after each change. A lost connection keeps the changes on the screen and sends them when it comes back. If the same script is open on two screens, the older one is told "This script was changed on another screen. Reload to carry on." and never overwrites the other.
  - **Submit** is offered once every question has a mark or NR; otherwise the screen lists the questions still to mark. After Submit the screen says "Submitted. You can still change it until marking closes." A change after Submit asks for a short reason, and every mark ever given is kept with who, when and why.
  - **"Name visible"** asks "Does this page show the candidate's name? The script will go back to staff and leave your list." with the page number and no text box (a marker might type the name). The script goes straight back to staff and that marker is not given any piece of that script again.
- **Hold ended.** If a hold runs out (a long break), the next save is refused in plain words, nothing saved is lost, and the marker carries on with Next script if nobody else has taken the script.

### For lead markers

- One marker per subject can be the lead marker. On /marking a lead also sees **"Needs your attention"** and **"Progress"** for the subjects they lead.
- **Needs your attention** lists the scripts of their subjects that need a decision: a page picture changed during marking ("Release", or "Release all" for an exam), a marker reported a name, or pages were set aside or changed ("Noted"). Each action asks for a reason. When Release is not possible yet, one sentence says why (for example, the script is with staff, or its pictures are still being made).
- **Progress** shows, per exam, the scripts waiting, ready, being marked and marked, and each marker's scripts taken and submitted.
- Lead markers are emailed about these alerts, as are the owner and admin accounts: one email per exam and kind of alert while it waits, saying how many scripts it is about. The emails carry the exam and the script number only, never a candidate's or a marker's name.

### For admins (and teachers, for their own subjects' questions)

- **Questions and mark scheme** (a link on the exam page, for admins, and for a teacher on their subjects' exams): one row per question and part (up to 3 levels and 200 questions), with its maximum (0.5 to 100), "Half marks", "Marked by levels", the pages it is answered on, its question group and "Optional with…". Each question has its marking points (M1, A1, L2 and so on, with marks and text), acceptable alternatives and guidance. "Optional questions" ("Answer 2 of these") and "Question groups" (for marking by question) are set here too. The top of the page shows the total ("Paper total: 60 marks"). "Attach the mark scheme PDF" takes one PDF of up to 20 MB, kept in its own private store that families can never reach. Once marking has opened the page says "Marking has started. Changes need a reason and are recorded.": an admin can still change wording, points, guidance and pages, raise or lower a maximum (not below a mark already given), and add a question (submitted scripts that include it are reopened for their marker). Removing a question or changing groups is refused. Teachers can then only read it.
- **Markers** (/admin/marking/markers): every exam corrector and teacher, with "Approve" per subject (a teacher only for subjects they teach), "Remove approval", "Make lead marker" (one per subject, shown as a badge) and "Declared conflicts" (find a candidate by index number, add a note). Each action asks for a reason that is kept in the audit log. Removing an approval, or adding a conflict, takes back the scripts that marker holds in that subject or of that candidate. If they have already marked that candidate, the page says "This marker has already marked {n} of this candidate's scripts. Take them back on the Marking page if they should be marked again."
- **Marking on the exam page:** "How it is marked" (Whole script or By question), "Marking deadline" (UK time), what is ready in plain words ("3 questions, 60 marks", "2 markers approved", "4 home scripts wait until 3 December, 12:30"), and "Open marking". Once open: "Close marking" and "Reopen marking", each with a reason. Closing stops hand-out, saving and changes; it ends and deletes nothing. The deadline never locks anyone out by itself: it turns the figures red.
- **When scripts are handed out.** A verified home script waits until 24 hours after the finish (families may still replace pages until then). A centre script waits until its centre's pages with no code or an unknown code are settled. No script is handed out while its pictures are being made again, while it is taken back, or while a late script waits for your decision.
- **Marking** (/admin/marking): progress per exam and per marker ("Overdue" in red once the deadline has passed with work left), every script of an exam with filters (state, marker), tick boxes, "Assign to…" (no time limit), "Take back", "Reassign to…" and "Assign the next {n} to…", each with a reason, and the alerts ("Needs attention"). The page shows script and index numbers, never a candidate's name.
- **The script page** (/admin/scripts/…): a script being marked says "This script is being marked. To change its pages, take it back from the markers." with **"Take back from markers"** (reason). Its pages can then be changed with the Phase 2 tools. **"Hand back to markers"** returns it once it is verified again: each piece goes back to its marker, and a marker whose pages changed is asked to check their marks.
- **Admin home page.** New marking figures: scripts left to mark, on hold in marking, marking alerts open and marking pictures to check; a row per exam whose marking is open or closed in the last 14 days (left, marked, on hold, deadline); and alerts: "Marking is overdue for {n} exams.", "{n} scripts are on hold in marking.", "{n} marking pictures wait to be checked." and "{n} assigned scripts have not been touched for a week."
- **Menus.** Admins and the owner have "Marking" and "Markers"; correctors and teachers have "Marking". The old demonstration pages (/examiner/marking and /examiner/papers) are gone.

### The two-step check of a page staff accepted

When the processing server cannot prove where a page's name band is, staff accept the page in the exception queue ("Hide the name", or "There is no name on this page"). Only then is its marking picture made, so staff have not yet seen what markers will see. So there is a second step:

1. Staff accept the page in the exception queue, as in Phase 2. The note now says "Accepted. When the marking picture is made, check it under Marking pictures to check."
2. Once the picture is made, it waits on the second tab of the exception queue, **"Marking pictures to check ({n})"**, with the full page and the marking picture side by side. Staff press **"The name is hidden"**, or **"A name still shows"** (with a reason), which sends the page back through "Hide the name".

Until step 2 is done the script is not verified. For a script already being marked (a paper hidden area changed, for example), none of its pieces is handed out and the lead marker cannot release it until the picture is checked.

### When a picture changes during marking

- When what a marking picture hides changes (a page turned, a hidden area changed), the script's pieces being marked or submitted are put on hold. The marks stay, the old picture can no longer be fetched, and the lead marker is told. The lead marker releases with one click once the new pictures are ready. A picture made again with exactly the same hidden areas holds nothing.
- When a page loses its marking picture, every piece of the script is held until staff take it back and hand it back.
- Scanned pages that arrive for a script being marked are set aside, as before. The lead marker and admins are told, and staff take the script back to place them.

### Phase 2's small fixes

- The "paper released" and "paper corrected" emails wait until the paper's page roles are checked (none is dropped).
- The "not sent yet" warning and the leave-page prompt show only while the family can still press Submit. After the upload time the page says "The upload time has ended. Your pages were not sent. Please contact the institution."
- On "Answers uploaded but not sent", a draft that replaces pages already received says so.
- Family emails queued while email was off: the admin home page says "{n} family emails are waiting to be sent." with **"Do not send them"** (a reason is asked for and kept). Staff alerts are never skipped.
- The 5,000-page limit is now tested at exactly 5,000 pages.

### The processing server

- It now deletes page pictures that nothing points at any more (pictures replaced by a remask or a rerun), once they are 24 hours old. It never deletes an original upload or scan, a picture of a file still being processed, or a picture any page row names.

## Calls for you to confirm or change

These were choices the design left open. Each can be changed later at a small cost. The full table is in docs/superpowers/plans/2026-11-21-phase3a-marking.md ("Builder's calls"); please look above all at 2, 5, 16 and 17.

1. **Markers see the index number** (call 17), as the design says. A teacher who marks can also run their subject's register, where index numbers stand beside names. If you prefer "script number only", that is one field to hide.
2. **After marking closes, a submitted script opens read only and without its pages.** The marker sees their marks but not the pictures. Privacy came first; nothing can change after close anyway.
3. **Home scripts are handed out from the finish + 24 hours** (call 2), because a family may replace pages until then and a script being marked is locked. Marking of home scripts starts a day later than it could. The wait is one setting.
4. **The marker who presses "Name visible" never gets any piece of that script back** through Next script (call 5). The whole script returns to staff at once. An admin can still assign it to them on purpose. In a subject with one marker, an admin must assign it back by hand.
5. **One extra click for each page staff accepted** (call 7): "The name is hidden" on the marking picture itself, as described above.
6. **Family emails queued while email was off are still sent** when it is switched on (call 16). The admin home page offers "Do not send them" first, with a reason. A family may otherwise get a receipt days late.

## Deploy order

Do not deploy until you give the go-ahead.

**Before you start**

- **Phase 1A and Phase 2 go live first, each with its own steps** (docs/superpowers/2026-11-18-phase1a-release-notes.md and docs/superpowers/2026-11-21-phase2-release-notes.md). Phase 3A is built on both.
- **Take a backup, or confirm point-in-time recovery is on,** for the live database.
- **Pick a time with no exam running and no marking open.**
- **Never run `supabase config push` from this repository.** Its settings point sign-in links at the local test copy.
- **The Next.js upgrade is still open.** Every build of the website still stops once on Next.js's security notice (it happened again in this part's builds; a second run then builds). Upgrading Next.js is its own, tested step, done only with your go-ahead, before deploying.

**Steps**

1. **Migrations 20261122000001 to 20261122000012**, after Phase 2's 20261120000050 to 20261120000076 (`npm run db:push`, by your go-ahead only). 001 is Phase 2's small fixes; 002 to 012 add the marking tables, questions and mark scheme, markers, opening marking, hand-out and holds, saving and submitting, held pieces and taking scripts back, the check of accepted pages' marking pictures, the picture clean-up, the reasons a release waits, and the admin dashboard's marking figures. 005 adds the scheduled job `marking-tick` (every minute).
2. **Edge Functions: redeploy `script-notify`** (its code changed for the marking alert emails; the "Do not send them" rule is in the database functions it calls, migration 001). The shared email code changed too (the marking alert email was added; nothing else in it changed), and five other functions are built with it (approve-student, paper-release-notify, parent-child, register-student, reject-student), so deploy every function with `npm run fn:deploy`. No new secret is needed.
3. **The processing server: this build** (with the picture clean-up). Deploy it after the migrations: it calls a function that migration 010 adds. Files queued meanwhile simply wait.
4. **The website.**

**Check afterwards**

- **The scheduled job `marking-tick`** exists on the live project (in the SQL editor, `select jobname, schedule from cron.job;` lists it with `* * * * *`), beside `script-notify`.
- **A test script goes from "Next script" to "Submitted":** approve a test marker for a test subject, enter one question, open marking for a test exam with a verified test script, then as the marker press Next script, give the mark and press Submit. The admin home page then shows it as marked.
- **The processing server's time limit is still there.** `select rolconfig from pg_roles where rolname = 'service_role';` must still show `statement_timeout=5min` (and `authenticated` still `statement_timeout=8s`).
- On the admin home page, the marking figures load ("No exam is being marked, and no marking closed in the last 14 days." on a live project with no marking yet).

## Owner actions

1. **Approve the first markers, and a lead marker for each subject** (/admin/marking/markers).
2. **Enter the first exam's questions and mark scheme** (the exam page, "Questions and mark scheme"), and attach its mark scheme PDF.
3. **Decide the calls above**, above all 2, 5, 16 and 17 of the plan's table.
4. **Run the full browser test run once** on a machine with port 3005 free and at least 3 GB of memory free: `npm run e2e:local -w @stem/web`. It builds the site, starts its own copy on port 3005 and the processing server, and runs every browser test, Phase 2's included. Here it could not be run (about 1.4 to 2.4 GB was free); the two marking browser tests were run against a stand-in copy instead (see "How it was tested").
5. **Mark a script on a real iPad with an Apple Pencil**, in Safari: write, scroll with one finger, zoom with two, rest a palm on the screen while writing, and use "Draw with finger". The tests used made-up Pencil and finger events only.
6. **The Next.js upgrade**, as its own step (see "Before you start").

## How it was tested

On the local test copy only:

- Database tests: 49 files, all passing (12 new in this part, 038 to 049).
- Edge Function tests: 189 passed (with the local functions server running).
- Processing server tests: 168 passed.
- Website tests: 431 passed; shared code tests: 201 passed; type checks and the linter clean (3 old warnings).
- The website build passes (after the Next.js notice, on the second run).
- Browser tests, against a stand-in copy of the site on port 3006 built with the local test copy's settings: the marking screen (6 tests: marking and submitting with mouse and keyboard, the iPad's Pencil and fingers, the phone message, "Name visible", a second screen) and the staff side (8 tests: entering questions, approving a lead marker, opening marking, assigning and taking back, a hidden-area change made by the real processing server putting a piece on hold and the lead releasing it, taking a script back and handing it back). In the staff test every page has no sideways scroll at 1,440, 820 and 390 px wide; in both, no marking page shows a candidate's name.
- Hand-out was timed with 1,500 scripts waiting: Next script took about 10 milliseconds, and assigning 200 at once about a quarter of a second.

## Known limits

- **Not in this part: double marking, seeded scripts, practice before live marking, lead marker review, marker statistics, approval to "checked" and marker payments** (Phase 3B). A script ends at "marked".
- **A marker can make a long-lived link to a marking picture** of a script they hold. The storage system checks who may read a picture only when a link is made; the website itself uses links that expire after 120 seconds. The pictures carry no name. The follow-up is to make the links on the server, after the permission check, and remove the markers' storage rule.
- **Every change to what a picture hides holds the pieces being marked,** even when the new picture looks the same (for example a hidden area that covers only blank paper). The lead marker releases them with one click (or "Release all" for an exam).
- **Home scripts wait a day** after the finish before they are handed out (see the calls above).
- **Question areas are not drawn on the page yet.** The questions say which pages they are on; drawing their areas comes with AI suggestions in a later phase.
- **The full browser test run and the real iPad check are still to do** (owner actions 4 and 5).
- **Taking back a home script sends Phase 2's "needs attention" staff email,** even when the script is verified again at once.
- **A scanned page set aside for a script being marked sends two emails:** Phase 2's "not expected" alert and the marking alert.
- **A marker who reports a name after marking has closed** reopens that piece although marking is closed. Changing the questions while marking is closed can also reopen submitted pieces.
- **A lead marker with a declared conflict for a candidate still sees "Release"** for that candidate's script; the system refuses it with a message.
- **Admins and the owner see "You are not approved to mark yet" on /marking.** They work from /admin/marking.
- **The markers page has no summary per subject** (how many are approved, who leads); each marker's card shows it.
- **Two people editing the questions of one exam before marking opens:** the last save wins, with no warning.
- **Replacing the mark scheme PDF after marking has opened needs no reason,** and the editor does not show the attached file's name or a link to open it.
- **The progress per marker counts the pieces of withdrawn or void scripts.** The figures per exam do not.
- **On the admin home page, "on hold" and "assigned scripts" count pieces.** For an exam marked by question, one script with three pieces on hold counts as 3.
- **A note typed at the very moment Submit is pressed may be lost.** If the connection drops after a save was sent and the screen is then reloaded, changes beyond the first 200 waiting may be lost without a message.
- **The picture clean-up looks through the whole picture store each minute.** That is quick today; it will need thinning out once there are many thousands of pictures.
- **The demonstration pages /examiner and /examiner/standardisation stay** as closed mock-ups until Phase 3B.

## Follow-ups for Phase 3B

- A second, seed, practice or re-mark pass is a new marking of that kind with its own assignment; the tables already allow it. Seed and practice passes may have several markers per script.
- The check pass gets its own state and moves scripts from "marked" to "checked".
- Next script has one place for "not the marker who did the first pass" and for mixing seeded scripts in.
- The exam's marking settings take 3B's sample size, tolerances and the switches for small subjects (with their reason); the per-exam clearance after practice sits beside the approvals per subject.
- The private notes to the lead marker, the active time per marking, the history of every mark and the marking alerts are written now, for 3B's review, statistics and tolerance alerts. Payments count the submitted live markings.
- Marks are recorded as given by the marker; "suggestion accepted" is added with AI suggestions, which also use the question areas and marking points.
- Sign marking picture links on the server and drop the markers' storage rule (see "Known limits").

## Not in this part

- Phase 3B: double marking, seeded scripts, practice before live marking, lead marker review and settling, marker statistics, approval to "checked", marker payments.
- A comments library, audio feedback and offline marking (Phase 5).
- Results for families (Phase 4).
- The Next.js upgrade (a separate step, with your go-ahead).
