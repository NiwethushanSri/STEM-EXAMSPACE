# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

- **Parents and guardians**: book and pay for mock exams for their children, follow bookings, results and notices. Usually the person deciding and paying.
- **Students**: from Year 5 (about age 9) up to GCSE and A level (about age 18). Older students book for themselves; every student has an index number and an index card for exam day.
- **Staff of one institution**: the Super administrator (owner, exactly one), admins, teachers, tutors, correctors (markers) and, later, invigilators. They run exams, bookings, payments, attendance and marking from the website on a computer or iPad.

## Product Purpose

Stem Examspace is the private system of a single education institution that runs mock exams. Families find a mock on the public timetable, book a seat and pay; on the day staff check students in by index card; scripts are scanned and marked on screen; results and feedback follow. Success: families can book without help, exam days run from the register, and every script is marked and reviewed in the system.

## Positioning

Mock exams run as a real exam would be: a fixed seat, an index number and card, a timed paper in a real room (or online), anonymous marking by index number with examiner-style annotations, and marks by question afterwards. It is one institution's own exam centre, not a marketplace or a tutoring platform.

The core of the platform is on-screen marking, in the spirit of RedMarker's rMarker (https://redmarker.io/rmarker): scanned scripts marked anonymously against a mark scheme, with double marking, quality checks and results analysis. Correctors mark on a tablet with a pen (iPad and Apple Pencil), so the marking screen must feel as natural as marking on paper. Booking is the front door; marking is the heart.

## Operating Context

- Question papers are handed out on paper in the exam room; answer scripts are scanned afterwards, one PDF per student per exam, and marked on screen, mostly on iPad with Apple Pencil.
- Staff use the website in a browser on a computer or iPad; there is no desktop program. A phone app for students and parents is being built separately (Expo).
- All times are UK time; all prices are in pounds (GBP). The institution is not VAT registered.
- The public site (home, timetable) is open to everyone; everything else needs sign-in.

## Capabilities and Constraints

- Built: accounts and roles, registration with admin approval, parent-child links, exams and venues, bookings (pay offline for now), cancellations and recorded refunds, finance totals, attendance with QR or typed index number, printable A6 index cards, staff home pages.
- Coming: Stripe card payments, scripts and marking (Part 3), results, analysis, notices and reminders (Part 4).
- Exams currently run: **GCSE and A level mocks only**. 11+ and university entrance tests (TMUA, FSAT, UCAT) are not run; the current site lists them and must stop doing so.
- Open: the audience starts at Year 5, but no Year 5–6 (11+) exams are run yet. Whether 11+ is coming is undecided.
- Owner answers to a 282-item questionnaire are in `docs/owner/owner-answers-summary.md` (repository root).

## Brand Commitments

- Name: **Stem Examspace**.
- Logo is fixed and must be used exactly as is: `public/images/stem-examspace-logo.png` (navy "STEM / EXAMSPACE" wordmark, the book, mortarboard and four-colour emblem, tagline "Learn. Practice. Excel."). Do not redraw, recolour or replace it.
- Contact address used on the site: hello@stemexamspace.co.uk.
- Visual style for public pages (owner's choice, 2026-11-15): bright, friendly and clean in the manner of Save My Exams (white and soft grey sections, Plus Jakarta Sans, pill buttons, rounded cards, hand-drawn blue rings and line drawings), in Stem Examspace's own navy, blue and emblem colours. A premium navy-and-serif alternative was tried and the owner preferred this one; changes from here are small refinements. Never copy that site's name, logo, images or copy. Its most recognisable devices (the blue hand-drawn ring, the role cards beside the headline) are the first candidates to make our own if resemblance becomes a concern.

## Evidence on Hand

- No testimonials, results statistics, reviews, partner schools or pass rates exist. Do not invent any.
- No photography of the institution, its rooms or students exists yet.
- Real content: the exam timetable (from the database), subject list, booking and exam-day process, the index card.

## Product Principles

1. Exam-day truth: every screen reflects how a real exam is run; nothing implies more than the institution does.
2. Parents decide; students sit the paper. Booking, paying and following results are written for a parent, while exam-day material speaks to the student.
3. Calm under pressure: exam days, marking sessions and payments are high-stakes moments; staff screens favour speed, clarity and no surprises.
4. Children's data is private by default: names and photos are shown only to those who need them.

## Accessibility & Inclusion

Users include children from about age 9 and parents of all backgrounds; copy stays plain and short. Target WCAG 2.2 AA. Staff screens must work on iPad with touch and Apple Pencil.
