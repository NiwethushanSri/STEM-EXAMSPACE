# Phase 1, part A: Home and centre sittings with personalised papers — Design

Date: 2026-11-17
Status: Approved by the owner 2026-11-18
Master plan: the owner's functional specification (`docs/owner/2026-11-functional-specification.pdf`), sections 8 to 10. Owner decision 2026-11-17: the specification wins where it differs from what is built.
Builds on: Part 1 and Part 2 (`2026-11-07-crm-foundation-design.md`, `2026-11-10-part2-exams-bookings-design.md`). Their rules still apply: row-level security on every table, writes only through checked SQL functions or Edge Functions, closed default privileges with explicit grants, an audit row in the same transaction as every staff change, no personal data in logs, no service-role key in the web app.

## 1. Why

The specification's Phase 1 ends with personalised paper PDFs. Every later phase depends on them: home scripts and centre scans are matched to a candidate by the code printed on each page (Phase 2), and markers see scripts without the candidate's name (Phase 3). The specification also asks to prove this early with real printers, phones and scanners, so this part includes a way to test that the codes read back.

Success:
- A family books an exam and chooses to sit it at home or at a centre, and which centre when there is more than one.
- An admin uploads the question paper once.
- At the release time (for example 09:50 for a 10:00 exam), a home candidate or their parent downloads a PDF made for that candidate: name, index number, exam code, date, page numbers and a QR code on every page, with the questions exactly as the board printed them.
- Before the release time nobody but staff can get the paper, from any screen or address.
- Staff print one pack per centre with every candidate's personalised paper for that centre.
- Every copy made and every download is recorded.
- An admin can photograph or scan a printed page and the system says whose page it is and which page.

## 2. Part of Phase 1, and what comes next

Phase 1 is finished in two parts, in this order:
- **A (this document):** home and centre sittings, the question paper, personalised copies, timed release, downloads, the centre print pack and the scan check.
- **B (separate design):** bring what is built up to the specification: year groups 8 to 13, registration statuses with rejected registrations kept with a reason, staff permissions per action and the coordinator role, importing existing students, exam series, and a booking reference and receipt.

## 3. Goals, non-goals and anti-goals

Goals: everything under Success above.

Not in this part:
- Families uploading finished scripts, the supervision screen with the countdown, and late submissions (Phase 2).
- Splitting bulk scans and the exception queue (Phase 2). The scan check here only reads codes and stores nothing.
- Hiding the candidate's name from markers (Phase 3). This part makes it possible by keeping the name in one fixed band.
- Coordinators and per-action permissions (part B). Until then, admins and the Super administrator do everything in this part.
- Computer-based tests, the question bank, different prices for home and centre.

Anti-goals (a failure even if it works):
- A paper reachable before its release time by a family, by any route.
- A candidate's name or index number inside the QR code.
- The questions moved, cropped or covered.
- A copy that cannot be traced to its candidate, booking and paper version.

## 4. Approaches considered

| Approach | How | Trade-off |
|---|---|---|
| **1. Make each copy when it is downloaded (chosen)** | The paper is stored once. When someone downloads, the server makes that candidate's copy, logs it and sends it. The same candidate always gets the same codes. | Nothing to store per candidate and always up to date. Downloads at 09:50 all happen at once, so each copy must be quick to make (a single copy is a few seconds at most). |
| 2. Make every copy at release and store them | A job makes all copies at the release time and stores them; downloads hand out stored files. | Downloads are instant, but many stored files with names on them, a job that must finish before 09:50, and stale files if the paper or a booking changes. |
| 3. Make the copy in the browser | The browser fetches the paper and adds the codes. | The browser must receive the plain paper, so a family could keep an unstamped copy and the download could not be recorded reliably. |

Approach 1 was chosen because it keeps the plain paper on the server, records every copy and needs no stored per-candidate files.

**Where the work runs.** Making a PDF is heavy work, and Supabase Edge Functions allow only about 2 seconds of processing per request, which a print pack for a full room would exceed. So:
- An Edge Function `paper-issue` does the checks and the light work. It runs as the caller, confirms they may have the paper now, creates or reuses the copy record, writes the download log, and returns the candidate details for the copy plus a link to the stored paper that expires within a minute.
- A website server route makes the PDF. It calls `paper-issue` with the caller's own session, fetches the paper through the short-lived link, adds the codes and sends the PDF.

The web app still holds no service-role key, and families never see the link to the plain paper. The phone apps (being built separately) will call the same website route with their session.

## 5. Design

### 5.1 Home or centre sitting

- An exam offers **at the centre**, **at home**, or **both**. Existing exams keep their meaning: "in person" becomes centre only, "online" becomes home only.
- A booking records the sitting the family chose: `centre` or `home`. The choice is made on the booking screen when the exam offers both. A family cannot change it later; an admin can, and the change is audited.
- **One exam, one or more centres** (owner decision 2026-11-17: "more than one, maybe"). An exam that offers the centre lists one or more centres. Each has a venue, a room, and its own seat limit. When an exam has more than one centre, the family picks one on the booking screen. With only one centre, the booking screen looks as it does today and nothing extra is asked.
- Seat limits are counted per centre. Home sittings have no limit for now.
- Existing exams keep their venue and room as their single centre, with the exam's current seat limit.
- An admin can move a booking to another centre of the same exam if that centre has a seat (audited).
- The exam-day register is per centre. Staff choose the centre, and only that centre's candidates are listed. Home candidates are never on a register.
- The public timetable shows each centre and its seats left, or "At home" when the exam is home only.
- One price for both sittings (owner can ask for separate prices later).
- Wording everywhere: "At the centre", "At home", "At the centre or at home" (replacing "In person" and "Online"). This includes the public timetable, the home page paper cards and the booking screens.

### 5.2 The question paper

- An admin uploads the paper for an exam as a PDF (at most 40 MB). Encrypted or unreadable PDFs are refused with a clear message.
- Stored privately (a new private storage area for papers). Only admins and the Super administrator can see or download the plain paper.
- Uploading again creates a new version. Older versions are kept, because copies made from them may already be printed. The exam shows which version is current, who uploaded it and when.
- Replacing the paper after any copy has been downloaded asks the admin to confirm and to give a reason (audited). Copies already made stay valid.
- If a published exam has no paper 24 hours before its release time, admins see a warning on the exam and on the admin home page.
- **Pages that are not A4 portrait** (design call): a landscape page is turned to fit an A4 portrait sheet, so the two bands always sit at the top and bottom of the sheet and Phase 3 can find them. A3 and other sizes are scaled down to fit A4. Only a page that cannot be read is refused.
- **Inserts** (design call): a paper can have extra documents that candidates read but do not write on, such as a data booklet, formula sheet or source booklet. They are uploaded separately on the same exam, released at the same time to the same people, and are not personalised, because no answers are written on them. Separate answer booklets are covered by the spare answer pages (5.3).

### 5.3 The personalised copy

Every page of the paper is placed on an A4 page, scaled down slightly so it fits between a band at the top and a band at the bottom. Nothing in the original page is moved within itself, cropped or covered.

```
┌────────────────────────────────────────────────┐
│ Amara Perera · SE-2027-0142   MATHS-P1H · 5 Jun │  ← top band (identity)
├────────────────────────────────────────────────┤
│                                                │
│         original exam page, scaled to fit      │
│                                                │
├────────────────────────────────────────────────┤
│ Page 3 of 18                          [QR]      │  ← bottom band (codes)
│ 7KQ2-M9XD · p03                                 │
└────────────────────────────────────────────────┘
```

- **Top band:** the candidate's full name, index number, exam code and the exam date. This is the only place the candidate's identity appears, so Phase 3 can hide it from markers by covering this band.
- **Bottom band:** "Page n of N", the QR code and the same code in readable characters for when a QR is damaged.
- **The QR code** holds only: a format marker, the copy code and the page number, with a check character. The copy code is random and means nothing without the database. No name, no index number, no booking number.
- **Spare answer pages:** after the paper's own pages, each copy has blank lined pages headed "Additional answer page" with a box for the question number, carrying the same bands and codes. The admin sets how many per exam (0 to 6, default 2).
- **Exam code:** a short code per exam (for example `MATHS-P1H-2027-06`), generated when the exam is created and editable by admins until the first copy is made.
- **The same codes every time:** a copy record links candidate, booking, paper version and copy code. Downloading again, or reprinting, produces the same pages with the same codes. A new paper version gives a new copy record.

### 5.4 Release time

- Each exam has a release time, stored as minutes before the start (default 10, allowed 0 to 120), so it moves with the exam if the date changes. It is set on the exam form and shown on the exam in London time.
- Before the release time, the server refuses home copies for everyone except admins. The check uses the database clock, never the device's.
- Admins can **release now** (early, with a reason) or **hold** the release (if something goes wrong), then release later. Both are audited with the admin's name, time and reason.
- **Hold after release** (design call): holding stops every family download, first or repeat, until the admin releases again. Families see "The paper is paused by the institution. Please wait."
- **Paper replaced after release** (design call): families who already downloaded see "A corrected paper is available. Download it again." on the booking, and get an email when email is switched on. The corrected paper has new codes. Pages from the old version still read back correctly, so scripts written on either version can be matched.
- Home copies can be downloaded from release until two hours after the exam's scheduled end. Phase 2 changes this to the submission deadline.
- When a paper is released, the student and linked parents get an email ("Your GCSE Maths Paper 1 is ready to download"), sent once per exam by a job that runs every minute. While email is switched off on the live project, nothing is sent and the rest still works.

### 5.5 Who gets a home copy

- The candidate, if their account is active and they have a paid home booking for the exam.
- Any parent linked to that candidate.
- Admins and the Super administrator, at any time.
- A paid booking with a cancellation request still waiting keeps its seat until an admin decides, so it gets its paper and is included in the centre print pack (design call).
- Not: unpaid, cancelled, refunded or expired bookings, or centre bookings. These see why ("Your booking is for the centre; your paper is handed out in the exam room").

Families see the paper on the booking: before release, "Your paper will be ready at 09:50 on Saturday 5 June"; after release, a download button; after a download, "Downloaded at 09:51 by Nimal Perera".

### 5.6 Centre print pack

- On the exam's admin page, **Print pack** makes one PDF per centre with every paid booking's copy for that centre, ordered by index number. Its cover page lists the exam, the centre and room, the date, the number of candidates, the paper version and when the pack was made.
- **Reprint** makes one candidate's copy again (a spoiled paper, a late booking). If the paper has not changed, it has the same codes as before. If the paper was replaced since the pack was printed, the reprint uses the current paper, and staff are warned that it differs from the pack (design call). The cover page of every pack shows the paper version it was made from.
- Admins can make print packs and reprints at any time. Both are logged.

### 5.7 Scan check

An admin page where staff upload a photo or a scan (an image or a PDF). The page reads every QR code it finds and shows, for each: exam, page n of N, candidate index number and paper version. Unreadable codes are listed as "No code found on page 2". Nothing is stored. This is how the institution tests real printers, phones and scanners before Phase 2.

### 5.8 What is recorded

- **Copy records:** copy code, booking, candidate, paper version, number of pages, created at.
- **Download log:** copy, who downloaded, when, and the kind (home download, print pack, reprint, admin preview). Families can see their own entries; admins see all.
- **Audit log:** paper uploads and replacements, release now, hold and release, sitting and centre changes, exam code changes.

## 6. Rules

- Every check that decides who may have a paper lives in the database or in `paper-issue`, never only in the screen.
- The plain paper is never sent to a family's device.
- Copy codes are random, at least 40 bits, unique across all exams, and never reused.
- Download links to the plain paper last at most 60 seconds and are only seen by the website server.
- Times are stored with their time zone and shown in London time, including around clock changes.
- A booking cancelled after a download keeps its copy record and log entries. The copy simply cannot be downloaded again.

## 7. Error handling

- Paper missing at release: families see "Your paper is not ready yet. The institution has been told." Admins see the warning (5.2).
- Making a copy fails: the family sees "The paper could not be prepared. Please try again." The download is only logged once the PDF has been made.
- Too many requests: one candidate can make at most 20 downloads per hour. Print packs are limited to admins.
- A page the scaler cannot place (an unusual size or rotation): the upload is refused with "Page 7 has an unusual size. Export the paper as A4 and upload it again."

## 8. Testing

- **A private database on this computer** (Supabase running in Docker Desktop) for every database test, so nothing touches the live project. The owner opens Docker Desktop before building starts.
- **Database tests** for release timing, who may download, seat counting per centre (including two families racing for the last seat at one centre), moving a booking between centres, audit rows and refusals.
- **Unit tests** for the QR content (writing and reading a code, check character, refusing tampered codes) and for building a copy from a sample paper: page count, spare pages, both bands present, nothing outside the page.
- **Browser tests** on this computer: an admin uploads a paper, a family downloads at release, the scan check reads a generated page back.
- **Real-world pilot** (owner): print copies on the institution's printers, photograph pages with several phones and scan them with the office scanner, and check every page reads back in the scan check.

## 9. Left to the builder

Table and column names, the QR library and error-correction level (it must survive a phone photo of a printed page), the exact band heights and fonts (readable when printed, inside normal printer margins), the code alphabet, how the website route streams the PDF, the job that sends release emails, and the layout of the admin and family screens within the existing design.

## 10. Open decisions from the specification

These have defaults here and can be changed later without rework:
- Paper release window: 10 minutes before the start by default, set per exam.
- Late policy and whether parents alone may upload: Phase 2.
- Exam fees: one price for both sittings.
