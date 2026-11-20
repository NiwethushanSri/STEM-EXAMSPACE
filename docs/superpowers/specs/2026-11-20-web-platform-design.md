# The rest of the web platform: scripts, marking, results, registration and public pages — Design

Date: 2026-11-20
Status: Draft for the owner's review
Master plan: the owner's functional specification (`docs/owner/2026-11-functional-specification.pdf`), sections 2 to 7 and 11 to 26. Owner decision 2026-11-17: the specification wins where it differs from what is built; its "decisions to confirm" stay open until the owner answers them.
Builds on: Part 1, Part 2 and Phase 1A (`2026-11-07-crm-foundation-design.md`, `2026-11-10-part2-exams-bookings-design.md`, `2026-11-17-phase1-papers-design.md`). Their rules still apply: row-level security on every table, writes only through checked SQL functions or server code, closed default privileges with explicit grants, an audit row in the same transaction as every staff change, no personal data in logs, no service-role key in the web app.

## 1. Why

Stem Examspace exists for its marking. Booking and papers (built) are the front door; what families pay for is a script marked carefully against a mark scheme, checked, and returned with marks per question and the examiner's notes on the page. None of the marking path exists yet: there is no way for a finished script to reach the system, no marking screen that saves anything (the `/examiner` pages are demonstrations that keep data in the browser), and no results.

The owner wants the platform open on 1 December 2026 and "100% fully functional", including marking in full. This document designs everything that is left, for the website, so the parts fit together; each part is then planned and built on its own, marking path first.

Success, end to end:
- A home candidate sits the paper under a parent's supervision with a countdown on screen, photographs or scans the pages, uploads them and gets a receipt.
- At a centre, staff record how many sheets each candidate handed in, who took the scripts where, and upload the scanner's PDF; the system splits it into one script per candidate by the code on every page.
- Anything the system cannot match goes to a queue a person resolves; nothing uncertain is matched automatically.
- Markers mark on a computer or an iPad with Apple Pencil, without seeing the candidate's name, question by question against the mark scheme, with ticks, crosses, notes and marks on a layer over the scan.
- A sample is marked twice without the second marker seeing the first; pre-marked scripts check markers along the way; a lead marker settles differences.
- An admin approves the marks, sets grade boundaries and publishes; families see marks per question, the annotated script and their child's progress.
- Staff, the public pages and the remaining owner answers are brought up to the specification.

## 2. Scope, order and what 1 December means

Owner decisions 2026-11-20:
- **Marking path first.** Build order: Phase 2 (scripts in) → Phase 3 (marking) → Phase 4 (results) → Phase 1B (registration and staff) → Phase 1C (public pages) → bookings and money extras → Phase 5 (AI help and apps).
- **Desktop first.** Every screen is designed for a computer first. Phones and iPads still work: families can photograph pages with the phone's browser, and markers can mark on an iPad with Pencil in the browser. Marking is not offered on phones.
- **A server prepares the scripts.** Uploaded scans and photos are turned into clean page pictures by a small processing server (section 5), not in the browser.
- **Design everything first**, then build part by part.

Honest timing: Phase 1A took about three days at the agreed care (a builder and an independent review for every step, a review of the whole branch, and tests on the local copy). With eleven days left, Phases 2 and 3 can be built and tested by 1 December if nothing slips; Phase 4 is at risk; 1B, 1C and the money extras will follow after opening. Families can already register, book and pay on the live site, and marking is not needed until the first exam has been sat, so the front door opens on 1 December either way. Each part is reported plainly as it finishes.

## 3. Goals, non-goals and anti-goals

Goals: everything under Success above.

Not in this design (later, or never without a new decision):
- The phone apps and the dedicated iPad marking app, including offline marking (Phase 5; the website must work without them).
- AI that marks. Section 11 describes AI **suggestions** as a later add-on; nothing AI is in the 1 December build.
- Computer-based tests, a question bank, SMS and push notifications (owner answers 242, 243: wanted, later).
- Selling the platform to other schools.

Anti-goals (a failure even if it works):
- A marker sees a candidate's name, or can tell whose script it is from anything on screen except the index number.
- A page is matched to the wrong candidate without a person confirming it.
- The original upload or scan is changed or lost; a mark changes without a record of who, when and why.
- A script is marked twice by mistake, or not at all without anyone noticing.
- A family sees another candidate's script, marks or rank, or a private examiner note.
- Results reach families before an admin approved them.
- "Uploaded" shown to a family before the server confirmed the file arrived whole.

## 4. Approaches considered

### 4.1 Where scans become clean page pictures

| Approach | How | Trade-off |
|---|---|---|
| 1. In the uploader's browser | The browser reads codes, straightens, splits and shrinks, as the 1A scan check and print packs do. | No new running cost, but big scanner batches need a desktop computer and phone photos get weaker correction. |
| **2. A processing server (chosen)** | Families and staff upload raw files to private storage; a small server in a container picks up each upload, prepares the pages and records the result. | Robust for any file from any device, best image tools; a new paid server the owner signs up for (about £10 a month, to confirm on the host's price page) and about two more days to build. |
| 3. A paid PDF annotation toolkit | Mark directly on PDFs. | Good pen tools out of the box, but a licence of thousands of pounds a year, marks buried inside PDFs, and blind double marking is harder. |

Owner decision 2026-11-20: approach 2. Supabase Edge Functions cannot do this work: they allow about 2 seconds of processing per request, and a single 20 MB paper already came close during 1A.

### 4.2 How marks sit on the script

Every approach keeps the original scan untouched (specification §16). Marks are stored as data on a separate layer per page and per marker: ticks, crosses, stamps, pen strokes, highlights, notes, each at a position given as a fraction of the page (the model already in `apps/web/src/lib/annotations.ts`). This makes blind double marking simple (the second marker's screen does not load the first layer), lets families see the marker's notes but not private ones, and lets results show the annotated page without making new image files.

### 4.3 Builder's calls recorded here (the owner can override)

- **Processing server:** Python 3.12 in a Docker container, because the best free image tools are in Python: `pypdfium2` (render PDF pages, Apache/BSD licence), `zxing-cpp` (read QR codes, Apache), OpenCV (find the page in a photo, straighten it, detect blur and blank pages, Apache), Pillow (save images). No AGPL libraries.
- **Host:** Fly.io in its London region, one always-on small machine (2 GB memory) that also scales to a second machine during busy hours. The container runs anywhere (Google Cloud Run, Render) if the owner prefers another host. The owner creates the account and adds the card; the builder never creates accounts.
- **Uploads:** Supabase Storage resumable uploads, so a phone that loses signal continues where it stopped instead of starting again.
- **Everything else:** the existing stack (Next.js website, Supabase database, storage and Edge Functions, pdf.js in the browser).

## 5. Phase 2: getting scripts into the system (specification §11 to §16)

### 5.1 The spine: from copy to script

Phase 1A gives every candidate's paper a copy code, and prints `SX1.<copy code>.<page>` as a QR code on every page, including the spare answer pages. Phase 2 reads those codes back.

- An **upload** is one file as it arrived (a phone photo, a home PDF, a scanner batch). It is stored untouched and never changed.
- A **page** is one page cut from an upload, turned the right way up, straightened, with its code read. Each page keeps a link to the upload and position it came from.
- A **script** is one candidate's answer pages for one exam: the pages in page-number order, built from one or more uploads. Home and centre scripts become the same kind of record (§16).
- Every script has a **version**. A later upload or a staff correction makes a new version; earlier versions are kept.

Script states (specification §16, shortened): `receiving` → `checking` → `needs_attention` (an exception is open) → `verified` → `ready_to_mark` → `marking` → `marked` → `checked` (double marking and moderation done) → `final`. Side states: `withdrawn` (booking cancelled or refunded), `void` (staff decision, with reason). A script cannot be marked until it is `verified` and has no open exception (§15).

### 5.2 Home sitting screen (§11)

On "My bookings", a home booking for an exam that starts today becomes the sitting screen:
- Before the start: the paper download (1A), the start and finish times in UK time, the rules and allowed materials (written by staff per exam, with a default per subject), the upload deadline and the late rule.
- **Parent acknowledgement:** before the start, a linked parent ticks "I will supervise this exam at home and follow the rules" (§11). It is recorded with the time. A student without a linked parent sees the rule that an adult must supervise; the acknowledgement is then the student's own, recorded as such.
- A plain warning that downloading early is possible and is not prevented (§11): "The paper is available 10 minutes before the start so you can print it. Please do not read it before the start."
- During the exam: a countdown to the finish. After the finish: "Upload your answers" with the time left before the deadline.
- Every home script is labelled `home` in all staff screens and results (§11, integrity).

### 5.3 Home upload and receipt (§12, §13)

Who: the student or a linked parent can upload; either can press "Submit". (Open decision 1.)

How, desktop first:
- **On a computer:** drop a PDF from a home scanner, or several photos.
- **On a phone:** "Photograph pages" opens the camera in the browser, one page at a time, with a page-shaped guide on screen. After each photo the page shows as a thumbnail. The family can retake, delete and reorder before submitting. A quick blur check runs on the phone and asks to retake a blurred photo.
- Files upload straight to private storage as they are taken, with a progress bar, and resume after a lost connection without making duplicates (§13).
- "Submit" sends the set to the processing server. The screen says **"Checking your pages"** until the server answers; it never says "received" before that (§13).

What the server checks and reports, page by page:
- the QR code belongs to this candidate's copy of this exam, and which page it is;
- every page of the copy is present; for missing pages the family is asked "Was page 6 left blank?" and can confirm or add it;
- duplicates (the same page twice: the clearer one is kept, the other set aside, not deleted);
- unreadable, too dark, cut off or blurred pages, with "Retake page 4";
- a page with no code (the candidate wrote on their own paper): the family says which page it follows; staff confirm it later in the exception queue.

Statuses shown to the family (§13): `uploading`, `checking`, `received` (all pages present and readable), `needs your attention`, `submitted late`, `rejected` (with the reason from staff). When received, the family gets a **receipt** on screen and by email to the student and linked parents: submission number, time, page count, exam, and a list of the pages. Submission number format: `S-<exam code>-<4 digits>`.

Resubmission (§13): until the deadline the family can replace the whole set or single pages; every earlier version is kept and staff see which one counts (the latest submitted before the deadline).

Deadline and late (open decision 2): uploads open at the start and close at **finish + 2 hours**, the end of the home window already used for downloads in 1A. After that, uploads are still accepted until **finish + 24 hours** but marked `late`; an admin decides per script whether it is marked. After 24 hours, uploads close and the family is told to contact the institution.

Staff are notified (email to admins, plus the operations dashboard) of every `needs attention`, late or rejected script (§13).

### 5.4 Centre collection and custody (§14)

The 1A register becomes the collection screen after the exam:
- Per candidate present: the number of sheets handed in (the printed copy counts as one booklet; extra sheets are counted separately). Absent candidates cannot have a script.
- **Collection manifest** (§14): a printable sheet per room with exam, centre, room, candidates in index order, present or absent, sheets per candidate and a box for the collector's signature. Its manifest number is printed as a QR code.
- **Custody** (§14): each handover is one record: from whom, to whom, where, when, with a note (for example "collected from Room 2 by A. Smith, 11:05", "handed to office, 11:20", "scanned, batch B-07", "archived, box 14"). Only staff can record custody. A script whose batch has no "scanned" record by the next day shows on the dashboard.
- Reconciliation (§14): the dashboard compares present candidates, sheets recorded and pages received after scanning, and flags missing or unexpected scripts.

### 5.5 Bulk scanning and splitting (§15)

- Staff upload one or more scanner files (PDF or images) for an exam, a centre and optionally a manifest number. Large files upload in parts and resume. Limit per file: 1 GB.
- The processing server splits each file into pages, removes blank backs from duplex scanning, turns pages the right way up using the QR code (mixed orientation is fine), reads each code and groups pages by candidate (§15). No separator sheets are needed, because every page carries its own code; a separator sheet with no code is detected as blank and ignored.
- Batch totals (§15): pages uploaded, matched, blank, flagged, and candidates complete. Staff see the batch fill in as the server works.
- A page that belongs to a different exam, a candidate not booked at this centre, or a candidate marked absent is flagged, never matched silently.
- Batch numbers: `B-<exam code>-<2 digits>`.

### 5.6 The exception queue (§15)

One queue for home and centre problems, filtered by exam. Each exception shows the page picture, what the server found and why it stopped. Kinds:
- no code or unreadable code;
- code from another exam or another candidate's copy than expected;
- duplicate page;
- missing pages (after the family's or the collector's count);
- a page added by a family with no code;
- a home upload after the deadline.

Staff resolve each by choosing the candidate and page (with search by index number), marking it blank or a duplicate, or rejecting it with a reason. Every resolution is recorded with who, when and the reason, and the original stays untouched; corrections are stored separately (§15). Only staff with the "resolve scripts" permission can do this (admins until Phase 1B).

### 5.7 The processing server

What it does for each upload, in one job:
1. Download the original from private storage and record its size and SHA-256.
2. Render PDF pages at 200 dots per inch, or read the photo.
3. For photos: find the page edges and correct the perspective; check blur, darkness and cut-off edges.
4. Read the QR code; turn the page so the code is at the bottom right as printed; straighten small tilts using the code's corners.
5. Detect blank pages.
6. Save two pictures per page: the **full page** (staff only) and the **marking page** with the top name band removed (34 points high in the 1A layout, located from the code's position). Markers only ever receive marking pages.
7. Record the page, its code, its quality checks and its link to the upload, then update the script and raise exceptions.

How jobs move: the website or a database function adds a row to a jobs table; the server takes the next job with a lock so two machines never take the same one, retries a failed job twice with a pause, and marks it failed with the reason after that (failed jobs show on the dashboard). Jobs are safe to run twice: running the same upload again replaces its pages and changes nothing else.

Security: the server holds the database's service key as a secret on the host, talks only to Supabase, and accepts no requests from the internet. Storage buckets are private; the website shows pictures through short-lived signed links handed out by checked database functions.

Storage buckets: `script-uploads` (originals, never changed), `script-pages` (full and marking pages).

Local testing: the server runs in Docker next to the local Supabase copy, and its tests use real fixtures: printed and scanned 1A copies, phone photos taken at angles and in poor light, a duplex batch with blank backs, a mixed-orientation batch, pages from two exams.

### 5.8 The script repository (§16)

Staff see every script with: script number, candidate (name hidden for markers), exam, source (home or centre, batch or submission), received time, page count, file fingerprint, verification state, marking state and version history. They can preview pages, rotate a page, and send an upload back to the server to be prepared again (§16). Withdrawn and void scripts stay visible with their reason (§16).

Retention (owner answers 176, 177; open decision 3): originals and pages are deleted automatically 12 months after results are published, unless a re-mark or complaint is open. Marks, results and the audit trail are kept.

## 6. Phase 3: marking (specification §17 to §21)

### 6.1 Questions and the mark scheme

Before marking, each exam's paper gets its **structure**, entered by an admin or a teacher of the subject:
- questions and parts (1, 2(a), 2(b)(i)…), each with its maximum mark;
- the page or pages where each answer is expected, so the marking screen jumps to the right place;
- the mark scheme per question: the marking points (for example "1 mark: speed = distance ÷ time"), acceptable alternatives and guidance; a PDF mark scheme can also be attached;
- optional questions (owner answer 185): "answer 2 of questions 5 to 7", with the best marks counted;
- whether the question is marked by levels (L1, L2, L3) for long answers.

The structure is locked once live marking starts; changing it afterwards needs an admin and a reason, and is recorded.

### 6.2 Markers

- Markers are staff with the existing `corrector` role. Teachers can also be approved to mark their subjects.
- An admin approves each marker for subjects, and marks one as **lead marker** per subject.
- A marker never marks a candidate they tutor or are linked to as a parent; those scripts are skipped for them.
- **Practice first** (owner answer 212): before live marking on an exam, a marker marks a few practice scripts already marked by the lead marker and sees the differences. The lead marker approves them for live marking. Practice marks never count.

### 6.3 Who marks what (allocation)

Per exam, an admin chooses how it is split:
- **Whole script** (default): one marker marks every question of a script.
- **By question:** questions are grouped, and each group is marked separately, so one marker marks question 3 for every candidate (RedMarker's random question allocation).

Markers press **"Next script"**: the system hands them the next unmarked piece for an exam they are approved for, in random order, and holds it for them for 2 hours. A piece is never handed to two markers at once, which stops duplicate marking (§16). An admin can also assign pieces to a marker, take them back, or reassign. Each exam has a **marking deadline** (owner answer 204); the dashboard shows what is left per exam and per marker.

### 6.4 The marking screen

Desktop first, three areas side by side:
- **Left:** the question list with the marks so far, and page thumbnails.
- **Centre:** the marking page picture, zoomable, with the annotation layer on top and a tool bar: tick, cross, the RM-style stamps already designed (BOD, ECF, TE, SEEN and others), pen, highlighter, text note, ruler, and an eraser for the marker's own marks.
- **Right:** the current question, its mark scheme and a mark entry (buttons 0 to the maximum, or typed), a private note to the lead marker, and the total.

Keyboard shortcuts on a computer (numbers for marks, letters for tools, arrows for questions, Enter for next). On an iPad, the Pencil draws and a finger scrolls and zooms (palm rejection from the browser's pointer events). Marks and annotations save as the marker works; reopening carries on where they stopped. The header shows the index number and "Name hidden", never the name. Phones see "Marking needs a computer or an iPad."

A piece is **submitted** when every question has a mark. Submitted marks can be changed by the same marker until the exam's marking closes, and every change is recorded.

### 6.5 Quality checks (§19 to §21; RedMarker and RM Assessor)

- **Double marking** (owner answer 211): a sample of each exam (default 10%, set per exam) is marked again by a second marker who sees neither the first marks nor the first layer. If the totals differ by more than the tolerance (default 10% of the maximum, set per exam) or any question differs by more than its tolerance, the piece goes to the lead marker.
- **Seeded scripts:** the lead marker marks a few scripts as definitive; they are mixed into markers' queues unannounced. A marker outside tolerance is shown the definitive marks; after three misses in a row the marker is paused until the lead marker approves them again.
- **Lead marker review:** settles double-marking differences (choosing one mark or setting their own), reviews a sample of each marker's work, and can send a marker's pieces back for re-marking with a note. All changes are recorded with reasons.
- **Marker statistics:** per marker and exam, the average mark given against the cohort, agreement with the second marker and with seeds, and speed.
- **Approval** (owner discussion point 12; open decision 4): an admin approves an exam's marking when every script is `checked`. Only then can results be prepared.

### 6.6 Marker payments (owner answer 203)

Each exam has a rate per script (or per question group when marked by question), set by an admin. The system counts each marker's submitted pieces that counted (practice and seeds excluded) and produces a monthly statement per marker and a CSV export. Paying markers happens outside the system.

## 7. Phase 4: results, progress and reports (specification §22 to §25)

### 7.1 Results

- **Calculation:** per candidate, the final mark per question after double marking and review, optional questions counted as the best allowed, the total, the percentage, and the grade.
- **Grade boundaries** (owner answer 186): set per exam by an admin after marking, with a preview of how many candidates fall in each grade before saving.
- **Rank** (open decision 5): shown within the same sitting mode by default (home and centre ranked separately, each with its cohort size), as §11 and §23 ask.
- **Publishing:** an admin publishes an exam's results at a chosen time. Families are emailed. Before publishing nothing is visible to families.

### 7.2 What families see (§23, §24)

- Per exam: total, percentage, grade, marks per question, the cohort average and spread (never another candidate's identity), and the annotated script: the marking pages with the marker's ticks, crosses and notes. Private notes to the lead marker are never shown.
- A **student progress** page: results over time by subject, with comparisons only between papers marked on the same scale (§23).
- A **parent dashboard** with a child switcher: upcoming exams, bookings, submission receipts, results and teacher comments (§24).
- A downloadable report per exam and a progress report per child (PDF).

### 7.3 Re-marks (owner answers 214, 215; open decision 6)

A family can ask for a re-mark within 14 days of publication, with a fee set by the admin. A different marker re-marks blind. The new mark stands whether higher or lower; the fee is refunded if the mark changes. Until online payment covers this, the fee is recorded as paid by an admin.

### 7.4 Staff dashboards and reports (§25)

- **Operations dashboard:** registrations pending, bookings, scripts expected against received, exceptions open, failed processing jobs, marking left per exam and marker, results waiting for approval. Filters by subject, centre, sitting mode and date.
- **Academic reports:** mark distribution, question difficulty (average mark per question), marker differences, cohort trends. CSV and PDF exports, each one recorded (§25).

## 8. Phase 1B: registration and staff (specification §2 to §5, §7; owner answers section A)

- **Year groups:** the owner described students as "G5 to 11 plus"; the specification says Years 8 to 13 (open decision 7). Year group becomes a field on the student, moved up each September.
- **Registration statuses:** rejected registrations are kept with a reason, which is emailed (owner answers 35 to 37); corrections keep the original value and who changed it.
- **Per-action permissions and roles:** permissions per action (create exams, approve registrations, release papers, resolve scripts, assign marking, moderate, approve marks, publish results, manage finance). Roles are named sets of permissions: Super administrator, admin, **coordinator**, teacher, tutor, marker (`corrector`), **invigilator** (owner answer 156: register and collection only).
- **Import existing students** from a spreadsheet, with a preview and a report of rows that failed.
- **Exam series** (owner answer 97): exams grouped into a series (for example "Year 11 Mocks, January 2027"), used by booking and reports.
- **Booking reference and receipt:** `BK-<6 characters>` on every booking, an emailed and printable receipt.
- **Clash warnings:** booking two exams that overlap warns the family.
- **Absence email** to families when a candidate is marked absent (owner answer 157).
- Small owner changes (owner answers section A): email links last 2 hours, an admin-only private note on students, parents can print their child's card, teachers and tutors can see photos for their register and their own students, students cannot delete their own account.

## 9. Phase 1C: public pages (specification §3)

- Public pages edited by staff without a developer: about, subjects, fees, exam formats, how to book, contact, and policies. Each page is text with headings, lists, links and images, with a preview before publishing.
- **Policies** (terms, privacy, cancellation) are versioned with an effective date; the version a family accepted at registration or booking is recorded.
- The remaining older screens are restyled in the current look.

## 10. Bookings and money extras (owner answers section B)

Designed in outline, built after 1C, each small: packages of papers, a waiting list, promo codes, a sibling discount, bank transfer, invoices, a cancellation policy with an admin fee, and finance exports for the accountant. Their detail is settled when they are planned.

## 11. Phase 5: AI help and apps (specification §26)

Later, and never instead of a person's decision (§26):
- **AI marking suggestions:** for each question, a model that reads images is given the marking page area, the question and the mark scheme points, and suggests a mark with its reasons and how sure it is. The marker sees the suggestion beside the script and accepts or changes it; only the marker's mark counts. Before use, suggestions are compared with examiners' marks on real scripts (§26). Only marking pages (without the name band) are sent. Costs roughly 10 to 30 pence per script, to be measured; families are told in the privacy notice.
- **Other help (§26):** explaining features, summarising trends for admins, suggesting revision topics from marks, finding stuck work; every academic comment is reviewed by staff before families see it.
- The phone apps and the iPad marking app with offline work call the same database functions as the website.

Phase 3 is built so suggestions can be added later without rework: questions have page areas, mark schemes are stored as points, and a mark has a source (`marker`, later also `suggestion accepted`).

## 12. Data (new tables, in outline)

Scripts: `script_uploads` (one file as it arrived), `processing_jobs`, `scan_batches`, `script_pages` (page picture, code, quality, source), `scripts` and `script_versions`, `script_exceptions`, `custody_events`, `collection_counts`, `sitting_acknowledgements`.
Marking: `exam_questions` (structure, page areas, maximum, optional groups), `mark_scheme_points`, `marker_approvals` (marker, subject, lead), `marking_units` (a whole script or a question group of a script), `marking_assignments` (who holds a unit, until when), `markings` (one marker's pass on a unit: kind live, second, seed, practice, re-mark), `question_marks`, `page_annotations`, `marking_reviews`, `marker_rates`.
Results: `grade_boundaries`, `results` (per candidate per exam), `result_publications`, `remark_requests`.
Staff and public: `permissions`, `role_permissions`, `exam_series`, `public_pages` and `public_page_versions`, `policy_versions`, `policy_acceptances`.

Every table has row-level security. Families read only their own children's rows; markers read only units they hold or have marked; nothing marker-facing contains names.

## 13. Rules

- Server time decides every deadline (UK time on screen, daylight saving handled).
- Private buckets only; pictures through signed links that expire within minutes, handed out after a permission check.
- Markers receive marking pages only (name band removed) and see index numbers, never names.
- Every staff action that changes a script, a mark, a structure, a boundary or a publication writes an audit row with a reason where the action asks for one.
- Originals are never changed or deleted except by the retention rule.
- No personal data in server logs.

## 14. Error handling

- Upload interrupted: resumes; the family sees progress and never "received" before the server confirms.
- Processing fails: retried twice, then shown on the dashboard with the reason; the family sees "We are checking your pages" and staff are alerted; nothing is lost because the original is stored first.
- Processing server down: uploads still land in storage and wait in the jobs table; the dashboard shows the queue age.
- Marker loses connection: work saved so far stays; the piece remains theirs until its hold expires.
- Two staff resolve the same exception: the second sees "already resolved by …".

## 15. Testing

As in 1A, on the local copy only, never the live project:
- database tests (pgTAP) for every new function and permission, including that markers cannot see names and families cannot see other candidates;
- processing server tests with real fixtures (section 5.7);
- unit tests for the website's logic;
- browser tests for each screen at desktop, iPad and phone widths, including Pencil-style pointer input on the marking screen;
- an owner trial before live use: print, sit, photograph, scan, upload, mark, double mark and publish one real exam end to end.

## 16. Owner actions (lead time)

- Create the processing server account (Fly.io, London) with a payment card, about £10 a month to confirm; or say which host you prefer.
- Email provider set up and switched on (launch items L3, L4), so receipts and results emails send.
- Privacy notice and terms that cover scanned scripts, marking and, later, AI suggestions; ICO registration (owner answer 265).
- Deploy Phase 1A first, with its release-note steps.

## 17. Open decisions (proposals in the text; the owner confirms or changes)

1. Who may upload home scripts: proposed student or linked parent (specification: "whether parents alone may upload").
2. Home deadline and late rule: proposed finish + 2 hours, then late until finish + 24 hours with an admin deciding.
3. Script retention: proposed 12 months after results.
4. Who approves marking before results: proposed an admin, after the lead marker's review.
5. Ranking: proposed within the same sitting mode, with cohort size shown.
6. Re-marks: proposed 14 days, blind, mark can go down, fee refunded if the mark changes.
7. Year groups: "G5 to 11 plus" (owner) or Years 8 to 13 (specification).
8. Double marking sample and tolerance: proposed 10% and 10% of the maximum.

## 18. Left to the builder

File and component names, exact table columns, image sizes and compression, the order of tasks inside each part, the camera screen's look within the existing design, and the wording of messages within the plain-English style already used.
