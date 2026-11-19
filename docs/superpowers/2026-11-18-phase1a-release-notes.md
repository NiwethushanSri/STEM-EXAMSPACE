# Phase 1A release notes: home and centre sittings, personalised papers

Written 19 November 2026 for the owner. Nothing in this part has been deployed. Everything below was built and tested on the local test copy of the system only.

## What changed

### For families (students and parents)

- **Choose where to sit.** An exam can now be sat at the centre, at home, or either. When it offers both, the booking screen asks which. When it offers more than one centre, the family also picks the centre and sees how many seats are left at each. A centre that is full says so and the family can choose another.
- **The paper on the booking.** Home candidates see their paper on "My bookings":
  - before release: "Your paper will be ready at {time} on {day date}";
  - after release: a download button, and the paper arrives with the candidate's name and index number on every page;
  - after downloading: "Downloaded at {time} by {name}";
  - if the institution pauses the release: "The paper is paused by the institution. Please wait.";
  - if the institution replaces the paper: "A corrected paper is available. Download it again.";
  - extra documents such as formula sheets appear under the paper with their own download button.
- **Centre bookings** say that the paper is handed out in the exam room.
- **Release emails.** When a paper is released, the student and linked parents get an email, and again if a corrected paper is issued. This only happens once email is switched on (see the launch items).
- Parents with several children see one clear button per child and exam.

### For staff

- The exam list, the exam form, the attendance register and the booking screens use the new wording: "At the centre", "At home", "At the centre or at home".
- Each centre of an exam has its own register. Staff choose the centre and see only that centre's candidates. Home candidates never appear on a register.
- An exam now finishes by itself two hours after its scheduled end (the end of the home download window). It no longer finishes when a register is closed.
- Teachers cannot open the paper pages.

### For admins

- **Exams at several centres.** The exam form lists one or more centres, each with a venue, room and seat limit. A centre that has had bookings is archived rather than deleted, so history stays intact. Existing exams keep their venue and room as a single centre.
- **Question papers.** Each exam page lets an admin upload the paper as a PDF (up to 20 MB), add inserts (data booklets, formula sheets), set how many spare answer pages each copy gets (0 to 6, default 2), and set the release time (minutes before the start, 0 to 120, default 10). Replacing a paper after copies exist asks for a reason and is recorded. Older versions are kept.
- **Release controls.** Release now (with a reason), hold, and release again. All are recorded with the admin's name, the time and the reason.
- **Missing paper warning.** A published exam with no paper close to its release time is flagged on the admin home page and the exam list.
- **Print packs and reprints.** One PDF per centre, every paid candidate's copy in index-number order, with a cover page. Reprint one candidate's copy at any time. If the paper changed since the pack was printed, the reprint warns that it differs.
- **Scan check** (/admin/exams/scan-check). Upload photos or scans (images or PDFs) of printed pages. The page reads each page's QR code and shows the exam, page number, candidate index number and paper version. Pages with no readable code are listed. Nothing is stored.
- **Download log.** Every home download and print is logged with who and when.

## Deploy order

Do not deploy until you give the go-ahead. The old website cannot read the new exam shape, so steps 1 to 3 must happen within a few minutes of each other, in this order:

1. **Migrations 20261118000045 to 20261118000049** (`npm run db:push`, by your go-ahead only). They add the centres, the sittings on bookings, the papers and copies, the private paper storage area, and the release email job.
2. **Edge Functions:** `paper-register`, `paper-copy` and `paper-release-notify`.
3. **The website.**

Check afterwards: the booking screen for an exam at one centre looks as it did, the admin exam page opens, and the timetable shows the new wording.

## Launch items

- **Release email settings (L13).** Set `CRON_SECRET` (a long random value) as a function secret, and set the Vault secrets `paper_notify_url` and `cron_secret` (the same random value). Until these exist the email job does nothing.
- **Email must be on** (launch items L3 and L4) for release emails to send. With email off, nothing is sent and nothing is marked, and the job only looks back 6 hours, so switching email on later never announces old releases.
- **Measure the paper limit.** Measure `paper-copy` on the hosted project with a real 20 MB paper before relying on the 20 MB limit. Locally a 20 MB paper took about 1.9 seconds to prepare, with one warning that the function was close to its CPU limit. If the hosted project is slower, the limit should be lowered.
- **Upgrade Next.js.** The website runs Next.js 16.4.4, which its own tooling flags as vulnerable on every build. Upgrade to a patched version as a separate, tested step before deploying.

## Owner trial

Before the first real home exam, test the whole path with real equipment:

1. **Print** copies on the institution's printers. Pages are scaled to 85% of A4 to make room for the name band at the top and the code band at the bottom. Check that the size is acceptable to read and write on.
2. **Photograph** printed pages with several different phones, and **scan** them with the office scanner.
3. **Run them through the scan check** at /admin/exams/scan-check.
4. **Report any page that does not read**, with the phone or scanner used. This tells us whether the code size and margins need changing before Phase 2.

## Not in this part

- Taking the completed home paper back: candidate upload, submission deadline and late handling (Phase 2).
- Marking, mark entry and results (Phase 3 onward).
- Online payment (a separate part). Today families still pay the institution directly.
- Separate prices for the two sittings, and a seat limit for home sittings. One price applies to both and home sittings are unlimited.
- Hiding the name band from markers (planned for marking).
