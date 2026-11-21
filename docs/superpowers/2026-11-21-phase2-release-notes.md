# Phase 2 release notes: getting the answers in

Written 21 November 2026 for the owner, and updated the same day after the final review (migrations 071 to 076). Nothing in this part has been deployed. Everything below was built and tested on the local test copy of the system only, with made-up files (see "Known limits").

Phase 2 takes every candidate's written answers into the system: home candidates photograph or upload their pages, centre staff collect and scan theirs, a processing server reads every page, and each candidate ends up with one checked script, ready for marking in Phase 3.

## What changed

### For families (students and parents)

- **The home sitting screen** is on "My bookings", under the paper. It shows the start and finish, until when answers count as on time and until when they are taken late, and a countdown that follows the server's clock, not the phone's. Before the start it says the paper is ready 10 minutes early for printing, asks the family not to read it yet, and reminds them to "Print at actual size (100%), not 'Fit to page'."
- **Rules and allowed materials.** Each exam shows its own rules and allowed materials, or the institution's default text when it has none (see "Home rules" below).
- **Supervision.** A linked parent confirms "I will supervise this exam at home and follow the rules". A student with no linked parent confirms "I will sit this exam under an adult's supervision". Who confirmed, and when, is shown and kept.
- **Handing in.** From the start of the exam the family can upload photos (on a phone the camera opens on the page, and a blurred photo is pointed out at once) or a PDF from a scanner or a scanning app, then press Submit. Up to 60 files at a time (120 in all for one hand-in, counting files added and deleted again); photos up to 25 MB each, PDFs up to 100 MB. A lost connection carries on where it stopped. Until Submit is pressed the screen says, in a box that stays in view, "Your pages are not sent yet. Press Submit to send them.", and the browser asks before the page is closed with pages uploaded but not sent. The screen tells families to photograph each page on its own, flat, from directly above, on a plain dark surface.
- **What the family sees next:** "Uploading", "Checking your pages" (usually a minute or two), then "Received" with the receipt "We have received your answers" (script number, pages, time, and a Print button), or "Needs your attention" with exactly what to do: "Retake page {n}" (or "Send as it is"), "Was page {n} left blank?", where a page without a code goes, or a file that could not be read. "Submitted late" and "Rejected" (with the institution's reason) are shown when they apply.
- **Deadlines.** Answers are on time until 2 hours after the finish. Until 24 hours after the finish they are taken but marked late, and the institution decides whether they are marked. After that the system refuses them.
- **Changing the answers.** Until the deadline the family can replace all pages or only some. Once marking starts nothing can change any more: the screen says "Your answers are already being marked."
- **Emails** to the student and linked parents: the receipt, "needs your attention" and "rejected". These only send once email is switched on.

### For centre staff

- **Sheets.** On each centre's register, a "Sheets" column records how many extra sheets each candidate who sat handed in (booklet + 0 to 50).
- **Collection manifest.** "Print collection manifest" makes a numbered PDF list of the candidates and their sheets (M-{exam code}-01, -02 and so on) to travel with the scripts.
- **Custody.** Every handover is recorded: collected, handed over, archived, from whom, to whom, where and when, with a note. "Scanned" is recorded by the scanning step itself.
- **Scanning.** On the exam page, staff start a scan batch (B-{exam code}-01, -02 ...), optionally with its manifest number, add the scanner's files (PDF, JPEG or PNG, up to 1 GB each; the screen advises about 500 pages per file), and press "Start processing". The totals update as pages are read: pages, matched, blank, duplicates, to check, set aside.
- **"All scans for this centre are uploaded"** checks every candidate marked present or late: complete scripts are marked complete, and missing pages go to the exception queue. It waits until every candidate on the register is marked and every file is processed.
- **Mark the register before scanning.** A centre candidate who is not marked is marked absent at the finish plus 2 hours, and that candidate's pages then come up as "not expected" in the queue.

### For admins

- **Exception queue** (/admin/scripts/exceptions). Every page the system is unsure about waits here: no code, an unknown code, another exam's page, a page of someone not expected (absent, another centre, another family's copy), a duplicate, missing pages, a page the family added, two paper versions in one script, poor quality, late, a name showing, a file that could not be processed. Each shows the page picture, what the server found in plain words, and the actions that fit, each with a reason that is kept in the audit log. "Hide the name" lets staff draw over a name on one page. A page that has a code always carries the printed name box, so it can only be accepted once a box is drawn over the name: the queue says "This page has a printed name box. Draw a box over the name before confirming." and offers no "There is no name on this page" tick for it (that tick remains for pages with no code).
- **Scripts** (/admin/scripts). Every script with filters (exam, home or centre, state, late), and each script's pages with the full picture and the marking picture side by side, its versions, files, custody and problems. Staff can turn a page, process a file again (only while nobody has worked on its pages), take a page out, or void a script, always with a reason.
- **Page roles and hidden areas.** On the exam page, each paper version's pages are marked as answer, cover, blank or information pages, and areas to hide from markers can be drawn on a sample copy. **The roles must be saved before the paper goes out:** until then "Release now" is refused, no copy is made for a family at the release time (they see that the paper is not ready), and print packs and reprints are switched off, each with a note pointing at the panel. The admin home page lists exams due for release within 24 hours whose roles are not checked. A replaced paper (a new version) must be checked again.
- **Answers uploaded but not sent** (/admin/scripts/unsent). Families who uploaded pages but never pressed Submit are listed here once the exam has finished, with a tile and a per-exam figure on the admin home page. Their files are kept (they are never deleted automatically). An admin or the owner can press "Submit for the family", with a reason that is kept in the audit log; the pages are then checked like any other hand-in, and marked late when the on-time deadline has passed.
- **Home rules** can be set per exam on the exam form.
- **Admin home page.** New scripts figures: problems to check, files that could not be processed and that staff have not dealt with yet, and how long the oldest file has waited; and for every exam of the last 14 days, the scripts expected (paid home candidates plus centre candidates marked present or late), received, verified, needing attention and late. Alerts say when the processing server seems stopped (a file waiting 15 minutes or more, or a file it stopped part-way through), when files could not be processed (until staff note or reject each one in the queue), when a centre's collected sheets have no scan recorded by 09:00 the next day, and how many problems wait in the queue.
- **Staff alert emails** to the owner and admin accounts. These problems send an email: answers handed in late, a file that could not be processed, a page without a code in a family's hand-in, pages that were not expected, pages of another exam, and a home script that needs attention. There is one email per kind of problem and file (per hand-in for a family's files), saying how many pages it is about, for example "12 pages of one file were not expected for this exam." Every other kind of problem is shown in the queue and on the admin home page only. Families' emails are always sent before staff alerts, and a family's receipt is tried for 7 days before it is given up.
- **What markers will see.** Each page has two pictures: the full page, for staff only, and a marking picture with the name band and every hidden area painted white. When the system cannot prove where the name band is, it makes no marking picture: the family is asked to retake the page, or staff check it.

### The processing server

A small program that runs separately from the website (in Docker, on the host in London). It takes one file at a time, reads each page's code, straightens and turns the page, checks blur, darkness and cut-off edges, makes the two pictures, and matches the page to its candidate. A file that fails is tried twice more; then it goes to the exception queue and the admin home page. A file of more than 5,000 pages is not read at all: it fails at once, and the queue tells staff to scan it again in smaller files. When a failed file is later processed (staff press "process again"), its problem in the queue closes by itself. Families' files are kept as they were uploaded and never changed. The server reads a large file from its disk, never whole in memory, and runs as a user with no rights.

## Deploy order

Do not deploy until you give the go-ahead.

**Before you start**

- **Phase 1A goes live first, with its own steps** (docs/superpowers/2026-11-18-phase1a-release-notes.md). Phase 2 is built on it.
- **Supabase Pro plan, and the upload limit raised to 1 GB** in the project's storage settings, before step 1. Without it, centre scans above the plan's limit fail.
- **Take a backup, or confirm point-in-time recovery is on,** for the live database.
- **Pick a time with no exam running.**
- **Never run `supabase config push` from this repository.** Its settings point sign-in links at the local test copy.
- **The Next.js upgrade from Phase 1A is still open.** Every build of the website still stops once on Next.js's security notice; upgrade it as its own tested step before deploying.

**Steps**

1. **Migrations 20261120000050 to 20261120000076** (`npm run db:push`, by your go-ahead only). They add page roles and hidden areas, scripts, uploads, pages, processing jobs, the exception queue, the home sitting, emails, collection and custody, scan batches, the script repository, and the dashboard figures (068 and 070). 071 to 076 are the final review's fixes: the printed name box (071), large files and large centres (072, 073), answers uploaded but not sent (074), page roles before release (075), and grouped staff emails (076). Migration 072 also lets the processing server's database calls run for up to 5 minutes (see "Check afterwards").
2. **Edge Functions: deploy `script-notify` (new) and redeploy `paper-copy` (changed in this phase: the sample copy for the page-roles panel, and the refusal while roles are unchecked).** `npm run fn:deploy` deploys every function, which also covers the shared email code the other functions use. Then the Vault secret `script_notify_url` (the function's address, `https://<project>.supabase.co/functions/v1/script-notify`). It uses the existing Vault secret `cron_secret` and function secret `CRON_SECRET` from Phase 1A. Until both secrets exist, no script email is sent.
3. **The processing server** on the host account in London (settings in `services/processor/fly.toml`: London region, 2 GB of memory). Give it `SUPABASE_URL` and the service key (`SUPABASE_SERVICE_ROLE_KEY`) as host secrets, never in a file. **Deploy it with migration 059 onward, from this branch:** migrations 059 to 066 change what the server and the database exchange, and from migration 061 on the database refuses the picture folder older builds of the server write to (067 to 076 change nothing an older build must send, but deploy this build: it checks a file's page count first, reads large files from disk and waits long enough for a large file to be recorded). Files uploaded before it starts simply wait in the queue; nothing is lost. A stop (a deploy or a restart) sends the server a stop signal and gives it 300 seconds, the most the host allows (`kill_signal = "SIGTERM"`, `kill_timeout = 300` in fly.toml): it finishes the file it is reading and takes no other. A file that needs longer than that is taken up again 15 minutes later.
4. **The website.**

**Check afterwards**

- The scheduled job `script-notify` (every minute) exists on the live project.
- The admin home page shows the scripts figures, with "Oldest file waiting: None".
- A test booking's photo goes from "Checking your pages" to "Received" within a few minutes.
- **The processing server's time limit.** In the SQL editor, `select rolconfig from pg_roles where rolname = 'service_role';` must show `statement_timeout=5min` (and `authenticated` still `statement_timeout=8s`). The migration also tells the API to read the setting again. To be sure it has, process one large test scan (a few hundred pages): if the file is read but then fails when its pages are recorded (the file's job shows the error "SupabaseError" on the script's page), restart the API in the project's settings (or run `notify pgrst, 'reload config';`) and process the file again. On the local test copy a 2,000-page file is recorded in under a second and "All scans for this centre are uploaded" for 300 candidates takes about a quarter of a second, so the 5 minutes are headroom, not a need.
- On the admin home page, "Uploaded, not sent" shows 0.

## Owner actions

1. **Supabase Pro plan and the 1 GB upload limit** (see "Before you start").
2. **A host account for the processing server, in London** (the settings assume Fly.io's London region; tell us if you prefer another host).
3. **Real test files:** a full centre pack from the office scanner, and photos and scanning-app PDFs of printed copies from several phones (old and new, iPhone and Android), including some taken on a white table and some on a pile of pages. Every threshold so far was set on made-up files; these real files set them properly. They are kept out of the code repository.
4. **The first real exam's date and size** (how many at home, how many at each centre), so the server size and the trial can be planned.
5. **Email on** (launch items L3 and L4) and the secrets in step 2. Family emails are kept for 7 days, so turning email on sends any family receipts and notices queued in the 7 days before. Turn it on before the first real exam, not during one.

## Home rules

Until Phase 1B brings subject management, there is one default text for the whole institution, shown for any exam without its own rules (a default per subject comes with Phase 1B):

- Sit the exam in a quiet room, with an adult supervising you.
- Start and stop at the times shown on this page. Do not read the paper before the start.
- Do not use notes, books, the internet, a phone or anyone's help unless the allowed materials say so.
- Write your answers on the printed paper, in dark ink or pencil, and keep every page.
- Print at actual size (100%), not 'Fit to page'.

Default allowed materials: "Pens, pencils, a ruler and a calculator if the subject allows one. No notes, books, phone or internet."

## Print at 100%

The marking picture is made only when the printed page proves where the name band is. Pages printed with "Fit to page" (smaller than about 90%) cannot prove it, so the family is asked to retake or reprint. If staff accept such a page instead, they must first draw a box over its printed name box, on that page: each page printed that way needs its own box, and the system refuses to accept it without one. Families are told to print at actual size (100%) before the start and in the default rules; the institution's own printers should print centre packs at 100% too.

## Known limits

- **Thresholds were set on made-up files only.** In tests about 3 in 100 clean phone photos are asked to be retaken; real files from the owner trial will tune this.
- **A name written somewhere else on a page.** When staff confirm a page and the hidden area they drew misses a name written elsewhere on it (for example down the margin), the marking picture shows that name. Staff must check the page carefully before confirming; in Phase 3 markers get a "Name visible" button.
- **Photos of a page lying on other pages, or taken at an angle,** are often asked to be retaken. In rare made-up cases (a curled page on top of a pile of other printed pages, flattened by a scanning app) part of a hidden area, and with the real line in shadow even the name, could still show. The photo advice, staff checks and the "Name visible" button are the safeguards; the owner trial with real piles decides whether an extra check, or a second printed mark in the top band, is needed.
- **A master paper with a full-width printed line close under the name band** (within about 8 mm) would make every page ask for a check. Look at real papers in the trial.
- **Page roles lock once the first answer page of that paper has been read.** After that they can no longer be changed for that paper version, which is why they must be saved before release.
- **Keep scan files to about 500 pages.** Larger files are read (up to 5,000 pages and 1 GB), but a smaller file is read sooner and is quicker to scan again if it fails.
- **Only some problems send an email** (see "Staff alert emails"); the rest wait in the queue and on the admin home page.
- **A reload during an upload** means adding that file again: an upload that was cut off by reloading or closing the page is not continued.
- **Drawing hidden areas with a finger on an iPad is awkward.** Use an Apple Pencil or a mouse.
- **Each page printed with "Fit to page" needs its own hidden area** before staff can accept it (there is no "same area for every page of this file" yet).
- **Plan more than one processing machine for a large home exam.** One machine reads one file at a time, at about 0.1 seconds per page plus the time to store the pictures; several hundred families handing in at the same moment wait in a queue.
- **A family is emailed that the paper is released (or corrected) even if its page roles are not checked yet;** the download is refused until they are. The admin home page warns the day before. To be fixed before launch (see "Small fixes before launch").
- **After the upload window has closed,** a family with uploaded but unsent pages still sees "Press Submit to send them" and a leave-page prompt, although Submit is no longer offered. Staff can still submit for them. To be fixed before launch.
- **The "Answers uploaded but not sent" list does not say when a draft replaces pages already received.** Submitting such a draft for a family after the finish plus 2 hours marks the script late. Families may still be uploading in the late window (24 hours after the finish), and submitting for them then drops any file still on its way, so wait until that window has closed where you can.
- **Right after a deploy,** two large files recorded at the same moment can make one of them wait while the database refreshes its statistics. If it waits too long it is simply tried again.
- **A file staff have worked on cannot be processed again** (the screen says so), so that their work is never undone.
- **Families cannot change a script once marking starts.**
- **"Please try again."** Rarely, when two staff act on the same file at the same moment, one of them is asked to try again. Nothing is lost.
- **No staff tool yet to reopen a family's upload window** after the late window (24 hours after the finish). Every such extension will need to be recorded when it is added.
- **Marking pictures can be rebuilt** (after a hidden area changes) for scripts already being marked. Phase 3 handles a picture changing during marking.
- **Phones holding many photos offline.** Up to 60 photos taken without a connection are held in the phone's memory until they upload (about 200 to 300 MB); try this on older phones in the trial.
- **Rejecting a late upload** when on-time pages exist still emails "rejected" about the late upload, although the on-time pages are used. The wording will be improved.
- **Old page pictures** left by files processed again, and marking pictures replaced after a hidden area changed, are kept in storage for now; a clean-up comes later (see the Phase 3 follow-ups).
- **Another candidate's page in a family's hand-in.** The family sees "Received" and gets the receipt, while on the staff side the script still needs attention until staff decide what to do with that page.
- **"Already in another candidate's script" problems can outlive their reason.** When a page staff placed in one script was also wanted by another, the problem stays open even after it no longer matters (for example the page went back where it was wanted), until staff close it.

## Follow-ups for Phase 3

- Never hand out or mark a script while its pages are being re-pictured (a remask job waiting or running).
- Wait until a centre's pages with no code or an unknown code are settled before handing out its scripts: a verified candidate may still be missing a page that sits in the queue.
- Handle a marking picture changing or disappearing during marking: hold the piece and tell the marking lead.
- "Name visible" from a marker on a script being marked needs a way to take the script back, because pages of a script being marked cannot be edited.
- Include the pages a family added (with no code) that staff confirmed, in their place.
- Decide whether scans may still add pages to a script being marked; today such pages are kept aside for staff.
- Markers may read marking pictures only (a storage rule for "-marking" pictures).
- When staff confirm a page, show them the marking picture first.
- Clean up page pictures no row points at any more: serve markers a page's current marking picture only, and delete the pictures it replaced.

## Small fixes before launch

Found by the last check of the fixes. None of them shows a name or loses a page.

- Send the "paper released" and "paper corrected" emails only once the page roles are checked.
- Show the "not sent yet" warning and the leave-page prompt only while the family can still press Submit.
- On the "Answers uploaded but not sent" list, say when a draft replaces pages already received.
- Decide whether turning email on should skip family emails queued before it.
- Test the 5,000-page limit at exactly 5,000 pages (today's test never reaches it).

## Not in this part

- Marking, mark entry and results (Phase 3 onward).
- Deleting scripts 12 months after results (Phase 4, once results exist).
- Per-subject default home rules (Phase 1B).
- A staff tool to extend a family's upload deadline.
