# Phase 1A release notes: home and centre sittings, personalised papers

Written 19 November 2026 for the owner. Nothing in this part has been deployed. Everything below was built and tested on the local test copy of the system only.

## What changed

### For families (students and parents)

- **Choose where to sit.** An exam can now be sat at the centre, at home, or either. When it offers both, the booking screen asks which. When it offers more than one centre, the family also picks the centre and sees how many seats are left at each. A centre that is full says so and the family can choose another. When every centre of an exam that can also be sat at home is full, the screen says "All centres are full. Choose At home." and only offers At home.
- **The paper on the booking.** Home candidates see their paper on "My bookings":
  - before release: "Your paper will be ready at {time} on {day date}";
  - after release: a download button, and the paper arrives with the candidate's name and index number on every page;
  - after downloading: "Downloaded at {time} by {name}";
  - if the institution pauses the release: "The paper is paused by the institution. Please wait.";
  - if the institution replaces the paper: "A corrected paper is available. Download it again.";
  - extra documents such as formula sheets appear under the paper with their own download button;
  - the page keeps checking by itself, so a family who opens it before the release sees the download button appear at the release time without reloading, and a paused or late paper shows as soon as it is ready. The server's clock decides, not the device's.
- **Centre bookings** say that the paper is handed out in the exam room.
- **Unpaid home bookings** say "Pay for this booking to get the paper."
- **Release emails.** When a paper is released, the student and linked parents get an email, and again if a corrected paper is issued. This only happens once email is switched on (see the launch items). A large exam is emailed over several minutes; nobody gets the same email twice. If every email fails (for example the email service is down), the job waits 15 minutes before trying again and stops after three failed tries.
- Parents with several children see each child's booking with its own download button. Screen readers hear the exam, the paper and the child's name on each button.

### For staff

- The exam list, the exam form, the attendance register and the booking screens use the new wording: "At the centre", "At home", "At the centre or at home".
- Each centre of an exam has its own register. Staff choose the centre and see only that centre's candidates. Home candidates never appear on a register.
- An exam now finishes by itself two hours after its scheduled end (the end of the home download window). It no longer finishes when a register is closed.
- Teachers cannot open the paper pages.

### For admins

- **Exams at several centres.** The exam form lists one or more centres, each with a venue, room and seat limit. A centre that has had bookings is archived rather than deleted, so history stays intact. Existing exams keep their venue and room as a single centre.
- **Question papers.** Each exam page lets an admin upload the paper as a PDF (up to 20 MB and 500 pages), add inserts (data booklets, formula sheets), set how many spare answer pages each copy gets (0 to 6, default 2), and set the release time (minutes before the start, 0 to 120, default 10). Changing the release time of a published exam asks for a reason, and every settings change is recorded with the old and new values. Replacing a paper after copies exist asks for a reason and is recorded. Older versions are kept. Names keep their accents on the paper (José Müller); only letters the paper's font cannot print are simplified (Łukasz becomes Lukasz).
- **Release controls.** Release now (with a reason), hold, and release again. All are recorded with the admin's name, the time and the reason.
- **Missing paper warning.** A published exam with no paper close to its release time is flagged on the admin home page and the exam list.
- **Print packs and reprints.** One PDF per centre, every paid candidate's copy in index-number order, with a cover page. The cover shows the paper version of the copies in the pack; if the paper is replaced while a pack is being made, nothing is saved and the screen asks to make the pack again. Reprint one candidate's copy at any time. If the paper changed since the pack was printed, the reprint warns that it differs.
- **Scan check** (/admin/exams/scan-check). Upload photos or scans (images or PDFs) of printed pages. The page reads each page's QR code and shows the exam, page number, candidate index number and paper version. Pages with no readable code are listed. Nothing is stored.
- **Download log.** Every download of a candidate's paper (home download, print pack copy, reprint and admin preview) is logged with who and when. Inserts (formula sheets, data booklets) are the same for everyone and their downloads are not logged.

## Deploy order

Do not deploy until you give the go-ahead. The old website cannot read the new exam shape, so steps 1 to 3 must happen within a few minutes of each other, in this order.

**Before you start**

- **Pick a time outside exam hours.** Between step 1 and step 3 the old website's registers, admin exam pages and timetable stop working.
- **Take a backup, or confirm point-in-time recovery is on,** for the live database. Migration 046 removes the exam's old venue, room and seat limit columns and 047 replaces the booking and attendance functions, so the only way back is to restore that backup.
- **Run this check on the live database and go ahead only if it answers 0.** It only reads:
  `select count(*) from exams where format='in_person' and (venue_id is null or room is null or seat_limit not between 1 and 1000);`
  Any other number means an existing exam cannot become a centre exam; fix those exams first.
- **Check that Vercel does not deploy `main` by itself from git.** If it does, merging this branch would put the new website live before the database is ready.
- **Phase 1A goes live first.** Other branches built at the same time have migrations dated 20261119 and later. They must reach live after these, and each must first be rebased onto Phase 1A and tested again, because they may use the removed columns or the old booking and attendance functions.
- **Never run `supabase config push` from this repository.** Its `supabase/config.toml` points sign-in links at `localhost:3005` (the local test copy) and would overwrite the live settings.

**Steps**

1. **Migrations 20261118000045 to 20261118000049** (`npm run db:push`, by your go-ahead only). They add the centres, the sittings on bookings, the papers and copies, the private paper storage area, and the release email job.
2. **Edge Functions:** `paper-register`, `paper-copy` and `paper-release-notify`.
3. **The website.**

**What happens to existing data in the first minutes.** The new job `complete-finished-exams` runs every 5 minutes. On its first run, every published exam that ended more than 2 hours ago becomes completed: on those exams, paid centre candidates on a register that is still open and were not scanned in are marked absent, and unpaid bookings expire. Payments and the finance figures are not changed.

**Check afterwards**

- The booking screen for an exam at one centre looks as it did, the admin exam page opens, and the timetable shows the new wording.
- All four scheduled jobs exist on the live project: `expire-unconfirmed-signups` (nightly), `expire-unpaid-bookings` (every 5 minutes), `complete-finished-exams` (every 5 minutes) and `paper-release-notify` (every minute). See launch item L10.

## Launch items

- **Release email settings (L13).** Set `CRON_SECRET` (a long random value) as a function secret, and set the Vault secrets `paper_notify_url` and `cron_secret` (the same random value). Until these exist the email job does nothing.
- **Email must be on** (launch items L3 and L4) for release emails to send. With email off, nothing is sent and nothing is marked, and the job only looks back 6 hours, so switching email on later never announces old releases.
- **Measure the paper limit.** Measure `paper-copy` on the hosted project with a real 20 MB paper before relying on the 20 MB limit. Locally a 20 MB paper took about 1.9 seconds to prepare, with one warning that the function was close to its CPU limit. If the hosted project is slower, the limit should be lowered.
- **Upgrade Next.js.** The website runs Next.js 16.4.4, which its own tooling flags as vulnerable on every build. Upgrade to a patched version as a separate, tested step before deploying.

## Known limits

- **Print packs for very large centres** are put together in the admin's browser. On an iPad or an older computer a pack of several hundred candidates may be slow or run out of memory; split the room or use a desktop computer until this has been tried.
- **The 20 MB paper limit** was measured on the local test copy only (see "Measure the paper limit" above).
- **QR codes on real phones and scanners** are not proven yet: that is the owner trial below.

## Owner trial

Before the first real home exam, test the whole path with real equipment:

1. **Print** copies on the institution's printers. Pages are scaled to 85% of A4 to make room for the name band at the top and the code band at the bottom. Check that the size is acceptable to read and write on.
2. **Photograph** printed pages with several different phones, and **scan** them with the office scanner.
3. **Run them through the scan check** at /admin/exams/scan-check.
4. **Report any page that does not read**, with the phone or scanner used. This tells us whether the code size and margins need changing before Phase 2.

## Not in this part

- Taking the completed home paper back: candidate upload, submission deadline and late handling (Phase 2).
- Marking, mark entry and results (Phase 3 onward).
- Online payment (a separate part).
- Separate prices for the two sittings, and a seat limit for home sittings. One price applies to both and home sittings are unlimited.
- Hiding the name band from markers (planned for marking).
