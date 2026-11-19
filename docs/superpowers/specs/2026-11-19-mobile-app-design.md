# Stem Examspace phone app for students and parents — Design

Date: 2026-11-19
Status: Draft for the owner's review. The prototype direction was approved 2026-11-19.
Master plan: the owner's functional specification (`docs/owner/2026-11-functional-specification.pdf`). Owner decision 2026-11-18: the website comes first, and the phone apps and the iPad marking app come later. This app is built **after the 1 Dec 2026 launch** and does not take time from it.
Builds on: Part 1, Part 2 and Phase 1A (`2026-11-07-crm-foundation-design.md`, `2026-11-10-part2-exams-bookings-design.md`, `2026-11-17-phase1-papers-design.md`). Their rules still apply: row-level security on every table, writes only through checked SQL functions or Edge Functions, closed default privileges with explicit grants, an audit row with every staff change, no personal data in logs, and no service-role key in any client.
Prototype: the Design canvas "Stem Examspace mobile" (private artifact, 14 screens for iPhone and Android).

## 1. Why

Students and parents check exams, bookings and cards on their phones, not at a desk. The website already does everything they need, but on a phone it is a page to find and sign in to each time. An app keeps them signed in, puts the next exam and anything unpaid on the first screen, and keeps the candidate card one tap away on exam day.

Success for the first release:
- A student or parent signs in once and stays signed in on that phone.
- A new family can register, and a parent can add a child. Both wait for staff approval, as on the website.
- The first screen shows the next exam and the list of things to do (pay, print a home paper).
- The timetable shows every published exam with the family's booking state on each one.
- A family books an exam and pays on the same Stripe page the website uses.
- The candidate card with its QR code opens without signal on exam day.
- A parent switches between children without signing out.

## 2. Who it is for

Students and parents only. Staff (admins, teachers, tutors, correctors, the Super administrator) keep using the website. Signing in to the app as staff shows "Staff use the website" with a link to it, and nothing else.

## 3. Scope

**First release (accounts and bookings):**
- Sign in, sign out, forgotten password (opens the website's reset page).
- Register a student or parent (pending approval), and a parent adds a child.
- Exam desk (the first screen): next exam card with a countdown, the to-do list.
- Timetable: published exams grouped by date, filtered by subject, with Booked, Held, Full and Book.
- Exam entry sheet: exam details, choice of child for parents, home or centre (and which centre) from Phase 1A, then pay.
- Bookings: each booking with its state, and cancellation requests.
- Candidate card: name, index number, QR code holding only the index number, kept on the phone for offline use.
- Family (parents): one folder tab per child.
- Me: account details, sign out, links to the website for anything else.

**Later releases, each after its website phase is built:**
- Home paper download at the release time (Phase 1A must be live on the website first).
- Upload script, page by page, with the blur check and the receipt (Phase 2).
- Supervisor's declaration for home sittings (Phase 2).
- Results with marks by question, trends and the examiner's note (Phase 4).
- Push reminders (exam tomorrow, payment hold ending, results out).
- Add to Apple Wallet and Google Wallet.

**Not in the app:** anything staff do, marking, money reports.

**Anti-goals (a failure even if it works):**
- The app showing or doing anything the website would refuse for the same person. The app never decides who can see what; the database does.
- A candidate's name in the QR code.
- A paper reachable before its release time.
- Card details entered anywhere except Stripe's own page.

## 4. Design

The look is the approved prototype: an exam paper and ink identity, not a generic app.
- Colours: paper `#F7F5EF`, card `#FFFFFF`, hairline `#E3DFD3`, ink `#16213E`, muted `#5A6273`, action blue `#2556D9`, amber `#8A4B00` on `#FBEFD9` for anything waiting, green `#1F6B3A` for done. Examiner red `#C8372D` is used only for marks and stamps.
- Subject colours, the same everywhere: Maths `#2556D9`, Physics `#6D3FD1`, Chemistry `#0E7C66`, Biology `#3F7D1F`. New subjects get a colour chosen by an admin on the website.
- Type: Space Grotesk for headings, IBM Plex Mono for index numbers, times, dates and countdowns, the system font for body text (SF on iPhone, Roboto on Android).
- The next exam is drawn as an exam cover: subject band, then Date, Start and Room boxes with an ink border.
- Navigation is native on each phone: the standard iPhone tab bar and Android's Material 3 navigation bar. Students: Desk, Timetable, Papers, Results, Me. Parents: Family, Timetable, Bookings, Results, Me. Tabs whose phase is not built yet are hidden, not shown empty, so the first release has Desk, Timetable and Me for students (their bookings show on the desk and the timetable) and Family, Timetable, Bookings and Me for parents.
- Fees show the real price from the exam. Text sizes follow the phone's text size setting, and every control is at least 44 points.

## 5. How it is built

- **Expo (React Native) app** in the same repository at `apps/mobile`, one code base for iPhone and Android. It uses `@stem/shared` for types, error codes and messages, so the app and website say the same thing for the same error.
- **Same back end.** The app talks to the same Supabase project with the public anon key and the signed-in user's session. It calls the same SQL functions and Edge Functions as the website (for example `create-booking`). No new tables are needed for the first release.
- **Session** stored in the phone's secure storage (Keychain on iPhone, Keystore on Android), never in plain storage.
- **Payment:** the app calls `create-booking`, opens the returned Stripe Checkout address in the phone's secure in-app browser, and Stripe returns to the app through a link the app owns. The app then reads the booking state from the database, as the website's success page does. Only Stripe's webhook marks a booking paid. Apple and Google allow outside payment for real-world services such as an exam sitting; this is confirmed when the app is submitted.
- **Offline:** the candidate card and the family's upcoming bookings are kept on the phone and refreshed when there is signal. Booking and paying need signal and say so.
- **Deep links:** links in emails (for example "your seat is confirmed") open the matching screen in the app when it is installed, and the website when it is not.

## 6. Errors

- No signal: a banner "Offline. Showing what was saved at 09:12." Actions that need signal are disabled with that reason.
- Session expired: back to sign in, then back to the screen the person was on.
- Account pending or rejected: the same messages as the website.
- Booking refused (full, deadline passed, too many unpaid): the shared message for that code.
- Stripe page closed without paying: the booking stays held until its hold ends, with "Pay now" on the desk.

## 7. Testing

- Shared logic (formatting, booking states, error messages) is tested once in `@stem/shared`.
- App screens: component tests with mocked Supabase responses.
- End-to-end on a real iPhone first (the owner's test phone), then Android: sign in, register, add a child, book and pay in Stripe test mode, card offline in airplane mode.
- All testing uses the separate test Supabase project (launch item L1), never the live one.

## 8. Before building

- Launch item L1, the separate test Supabase project, must exist.
- Stripe (Part 2 Task 11) must be live on the website.
- Apple Developer and Google Play developer accounts, created by the owner in the institution's name.
- App name, icon and store listing text, approved by the owner.
