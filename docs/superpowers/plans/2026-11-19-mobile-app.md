# Phone App (Students and Parents) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The first release of the Stem Examspace phone app for iPhone and Android: sign in, register, add a child, exam desk, timetable, booking and paying, bookings, offline candidate card, family tabs.

**Architecture:** One Expo (React Native) app at `apps/mobile` in the existing npm-workspaces monorepo. It talks to the same Supabase project as the website with the anon key and the user's session, and calls only SQL functions and Edge Functions that already exist (plus Part 2 Task 11's payment function). Logic shared with the website moves into `@stem/shared` so both say the same thing.

**Tech Stack:** Expo SDK 54, expo-router, TypeScript, @supabase/supabase-js, expo-secure-store, @react-native-async-storage/async-storage, @react-native-community/netinfo, expo-web-browser, expo-linking, react-native-qrcode-svg, expo-font with Space Grotesk and IBM Plex Mono, jest-expo with @testing-library/react-native, Maestro for device flows, EAS Build.

**Spec:** `docs/superpowers/specs/2026-11-19-mobile-app-design.md`

## Global Constraints

- Built after the 1 Dec 2026 launch; never takes time from it.
- Students and parents only. Any staff role sees only "Staff use the website" with a link to `https://stem-examspace.vercel.app`, decided by `homeFor(role, status, "mobile")` returning `/use-desktop`.
- No service-role key in the app. Only `EXPO_PUBLIC_SUPABASE_URL` and `EXPO_PUBLIC_SUPABASE_ANON_KEY`.
- The app never decides who can see what: every read goes through RLS, every write through an existing RPC or Edge Function.
- QR code holds only the index number.
- Card details only on Stripe's own page; only Stripe's webhook marks a booking paid.
- Colours: paper `#F7F5EF`, card `#FFFFFF`, hairline `#E3DFD3`, ink `#16213E`, muted `#5A6273`, blue `#2556D9`, amber `#8A4B00` on `#FBEFD9`, green `#1F6B3A`, red `#C8372D` (marks and stamps only). Subjects: Maths `#2556D9`, Physics `#6D3FD1`, Chemistry `#0E7C66`, Biology `#3F7D1F`.
- Fonts: Space Grotesk headings, IBM Plex Mono for index numbers, times, dates and countdowns, system font for body.
- All times shown in Europe/London, whatever the phone's time zone.
- Text follows the phone's text size; every control is at least 44 points.
- Tabs: students Desk, Timetable, Me; parents Family, Timetable, Bookings, Me. Papers and Results tabs are not added in this plan.
- All tests run against the separate test Supabase project (launch item L1), never the live one.
- Error copy comes from `messageFor` / `bookingMessageFor` in `@stem/shared`, never written again in the app.

## Before Task 1

Ruling recorded in the ledger: Tasks 1 to 7 need only what is on `main`. Task 8 (payment) needs Part 2 Task 11 merged. Task 5's home or centre choice needs Phase 1A merged; if it is not merged when Task 5 starts, Task 5 ships without the choice and the choice is added in Task 8.

## Review Focus

1. **Session too large for secure storage.** expo-secure-store refuses values over 2048 bytes on some devices, and a Supabase session is larger. Expected: the session is still stored securely and survives a restart. Test in Task 2.
2. **Sign out leaves the last family's data on the phone.** Expected: signing out, or the session ending, wipes the cached card and bookings. Test in Task 7.
3. **Phone set to another time zone.** Expected: a 10:00 London exam shows 10:00, and the countdown is still right. Test in Task 1.
4. **Parent with no active children.** Expected: Family shows "Add a child" and booking says who can be booked, not an empty picker. Test in Tasks 5 and 6.
5. **Coming back from Stripe without paying, or the app killed on the Stripe page.** Expected: the booking shows as held with "Pay now" until the hold ends, then disappears. Test in Task 8.

---

### Task 1: Move booking and time helpers into `@stem/shared`

**Files:**
- Create: `packages/shared/src/money.ts`, `packages/shared/src/exam-state.ts`, `packages/shared/src/desk.ts`
- Create: `packages/shared/src/money.test.ts`, `packages/shared/src/exam-state.test.ts`, `packages/shared/src/desk.test.ts`
- Modify: `packages/shared/src/index.ts`; `apps/web/src/lib/money.ts` and `apps/web/src/lib/exam-state.ts` become re-exports from `@stem/shared`, and their existing tests keep passing unchanged.

**Interfaces:**
- Produces: `formatPence(p: number): string`, `formatLondon(ts: string): string`, `formatMoney(p: number): string` (moved unchanged).
- Produces: `isClosed(exam: { booking_deadline: string; starts_at: string }, now: Date): boolean` (moved unchanged).
- Produces: `londonParts(ts: string): { weekday: string; day: string; month: string; time: string }`. Example: `"2026-12-06T10:00:00Z"` gives `{ weekday: "SAT", day: "06", month: "DEC", time: "10:00" }`.
- Produces: `countdown(target: Date, now: Date): string`, giving `"17d 04h"` for 17 days 4 hours or more than a day, `"03:12:09"` under a day, and `"Started"` at or after the target.
- Produces: `type DeskBooking = { id: string; status: BookingStatus; examStartsAt: string; holdExpiresAt: string | null; subject: string; paper: string }` and `type Todo = { kind: "pay"; bookingId: string; until: string } | { kind: "print"; bookingId: string; opensAt: string }`.
- Produces: `deskTodos(bookings: DeskBooking[], now: Date): Todo[]`. A `pay` todo is created for each `awaiting_payment` or `reserved` booking whose hold has not ended. `print` waits for Phase 1A and returns nothing here.
- Produces: `nextExam(bookings: DeskBooking[], now: Date): DeskBooking | null` returns the earliest `paid` or `paid_offline` booking that has not started.
- Produces: `rowState(exam: { seats_left: number; booking_deadline: string; starts_at: string }, booking: { status: BookingStatus } | undefined, now: Date): "booked" | "held" | "full" | "closed" | "bookable"`.

- [ ] **Step 1: Write the failing tests**, including these cases:
  - `londonParts("2026-07-01T09:00:00Z").time === "10:00"` (BST) and `londonParts("2026-12-06T10:00:00Z").time === "10:00"` (GMT). Run them with `process.env.TZ = "America/New_York"` set at the top of the file.
  - `countdown` gives `"17d 04h"`, `"00:38:12"` and `"Started"`.
  - `deskTodos` ignores a hold that ended one minute before `now`.
  - `rowState` returns `"booked"` over `"full"` when the family holds a paid seat in a full exam.
- [ ] **Step 2:** Run `npm test -w @stem/shared`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement the helpers. Move the two web files' bodies into shared, and leave `export * from "@stem/shared"`-style re-exports of those names in web.
- [ ] **Step 4:** Run `npm test -w @stem/shared`, `npx vitest run -c apps/web` (or the web test script) and `npm run build -w @stem/web`. Expected: all PASS.
- [ ] **Step 5:** Commit: `feat(shared): London time, countdown and desk helpers shared with the app`.

### Task 2: Expo app shell, theme and secure session

**Files:**
- Create: `apps/mobile/` (`package.json` named `@stem/mobile`, `app.config.ts`, `tsconfig.json`, `metro.config.js` for workspace resolution, `jest.config.js`).
- Create: `apps/mobile/src/theme.ts`, `apps/mobile/src/supabase.ts`, `apps/mobile/src/secure-storage.ts`, `apps/mobile/app/_layout.tsx`, `apps/mobile/app/use-desktop.tsx`.
- Test: `apps/mobile/src/secure-storage.test.ts`, `apps/mobile/app/use-desktop.test.tsx`.

**Interfaces:**
- Produces: `colors` (the Global Constraints values as named keys: `paper, card, hairline, ink, muted, blue, amber, amberBg, green, red`), `subjectColor(name: string): string` (falls back to `colors.ink`), and `fonts = { heading: "SpaceGrotesk_700Bold", mono: "IBMPlexMono_600SemiBold" }`.
- Produces: `secureStorage: SupportedStorage`. The value is encrypted with AES-256 and kept in AsyncStorage, under a random key held in SecureStore. This is the "large secure store" pattern, so the 2048-byte limit never applies.
- Produces: `supabase: StemClient = createStemClient(url, anonKey, { storage: secureStorage, persistSession: true })` with `autoRefreshToken` on and refresh paused while the app is in the background (`AppState`).

- [ ] **Step 1: Write failing tests:**
  - `secureStorage` round-trips a 6 000-character value.
  - `getItem` on a missing key gives `null`.
  - The raw AsyncStorage value does not contain the plain text.
  - `use-desktop` renders "Staff use the website" and a link to `https://stem-examspace.vercel.app`.
- [ ] **Step 2:** Run `npm test -w @stem/mobile`. Expected: FAIL.
- [ ] **Step 3:** Scaffold with `npx create-expo-app@latest apps/mobile --template tabs`, then strip the template screens. Add the fonts, theme, storage and client. `_layout.tsx` loads the fonts and holds the splash screen until they load.
- [ ] **Step 4:** Run `npm test -w @stem/mobile`, then `npx expo start` and open the app on the iPhone in Expo Go or a development build. Expected: tests PASS and the app opens to a blank paper screen.
- [ ] **Step 5:** Commit: `feat(mobile): Expo app shell, theme and secure session storage`.

### Task 3: Sign in, status routing and sign out

**Files:**
- Create: `apps/mobile/app/sign-in.tsx`, `apps/mobile/app/status/[state].tsx`, `apps/mobile/src/session.tsx`.
- Test: `apps/mobile/app/sign-in.test.tsx`, `apps/mobile/src/session.test.tsx`.

**Interfaces:**
- Consumes: `indexLogin(client, indexNumber, password)`, `normaliseIndexNumber(raw)`, `homeFor(role, status, "mobile")`, `messageFor(code)`.
- Produces: `SessionProvider` and `useSession(): { state: "loading" | "signed-out" | "signed-in"; profile: { id: string; role: AppRole; status: AccountStatus; first_name: string; last_name: string } | null; signOut(): Promise<void> }`.
- Produces: `onSignOut(fn: () => Promise<void>): () => void`, a registry that runs before the session is cleared. Task 7 registers the cache wipe here.

- [ ] **Step 1: Write failing tests.** The identifier rules match the web login:
  - an identifier containing `@` calls `signInWithPassword`;
  - otherwise it calls `indexLogin` and then `supabase.auth.setSession`.
  - A pending student lands on `/status/pending`, a teacher on `/use-desktop`, and an active parent on `/home`.
  - An `invalid_credentials` result shows `messageFor("invalid_credentials")`.
  - `signOut` runs every `onSignOut` callback before `supabase.auth.signOut`.
  - When the token refresh fails, the app goes to sign-in with the current route kept as `next` and returns there after signing in.
- [ ] **Step 2:** Run `npm test -w @stem/mobile`. Expected: FAIL.
- [ ] **Step 3:** Build the sign-in screen as on the prototype's sign-in board. "Forgotten password" opens `https://stem-examspace.vercel.app/forgot-password` through `WebBrowser.openBrowserAsync`. Check that path exists in `apps/web/src/app`; if it is named differently, use the real name.
- [ ] **Step 4:** Run the tests. Expected: PASS. Then sign in on the iPhone with a test account from the L1 test project.
- [ ] **Step 5:** Commit: `feat(mobile): sign in by email or index number, status screens, sign out`.

### Task 4: Register a student, parent adds a child

**Files:**
- Create: `apps/mobile/app/register.tsx`, `apps/mobile/app/(parent)/add-child.tsx`, `apps/mobile/src/forms.ts`.
- Test: `apps/mobile/src/forms.test.ts`, `apps/mobile/app/register.test.tsx`.

**Interfaces:**
- Consumes: `registerStudent(client, RegisterStudentInput)`, `parentChild(client, { action: "register", child })` and `parentChild(client, { action: "link", indexNumber, dateOfBirth })`.
- Produces: `validateRegister(input): { ok: true; value: RegisterStudentInput } | { ok: false; errors: Partial<Record<keyof RegisterStudentInput, string>> }`. Use the same rules and wording as `apps/web/src/lib/register-form.ts`. If that file's rules are pure, move them into `@stem/shared` and use them from both.

- [ ] **Step 1: Write failing tests:**
  - A date of birth giving an age under 8 or over 25 is refused.
  - A result of `{ ok: true }` always shows "Check your email" (the server never tells whether an address exists).
  - `link` success shows "Request sent. The institution will approve it."
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Build both screens, as on the paper-form board.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(mobile): register a student and add a child`.

### Task 5: Timetable, exam entry sheet and bookings

**Files:**
- Create: `apps/mobile/app/(tabs)/timetable.tsx`, `apps/mobile/app/exam/[id].tsx`, `apps/mobile/app/(tabs)/bookings.tsx`, `apps/mobile/src/queries.ts`.
- Test: `apps/mobile/src/queries.test.ts`, `apps/mobile/app/exam/[id].test.tsx`.

**Interfaces:**
- Consumes: `rowState`, `isClosed`, `londonParts`, `formatPence`, `bookingMessageFor`, `subjectColor`.
- Produces: `loadTimetable(client, now: Date)`, which reads `exams_public` with the web's columns `id, subject, format, venue, starts_at, duration_minutes, price_pence, booking_deadline, seats_left`, with `starts_at > now`, ordered by start time, limit 200.
- Produces: `loadMyBookings(client)`, which reads `bookings` with the web's select (`id, status, amount_pence, student_id, created_at, exam:exams(id, status, starts_at, duration_minutes, format, subject:subjects(name), venue:venues(name))`).
- Produces: `loadChildren(client, parentId)`, which reads `parent_children`, then the active `profiles` rows.
- Produces: `book(client, examId, studentId): Promise<{ ok: true; bookingId?: string } | { ok: false; message: string }>` via `rpc("create_booking", { p_exam, p_student })`.
- Produces: `requestCancellation(client, bookingId)` via `rpc("request_cancellation", { p_booking })`.

- [ ] **Step 1: Write failing tests:**
  - `book` maps `too_many_unpaid` to `bookingMessageFor("too_many_unpaid")`.
  - A transport error maps to `messageFor("internal")`.
  - A parent whose children are all pending sees "None of your children can be booked yet. They need to be approved first." and no Book button.
  - The timetable groups by London date even with `TZ=America/New_York`.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Build the screens:
  - the timetable has date headings, a time column, a subject colour bar and Booked, Held or Full stamps;
  - the entry sheet has the child picker for parents;
  - the bookings list has its cancellation request.
  - If Phase 1A is merged, read its `create_booking` signature from the latest migration and add the home or centre choice exactly as the web booking page does. Otherwise leave it for Task 8.
- [ ] **Step 4:** Run the tests. Expected: PASS. Then book a test exam on the iPhone against L1.
- [ ] **Step 5:** Commit: `feat(mobile): timetable, booking and bookings list`.

### Task 6: Exam desk, family tabs and role tab bars

**Files:**
- Create: `apps/mobile/app/(tabs)/_layout.tsx`, `apps/mobile/app/(tabs)/desk.tsx`, `apps/mobile/app/(tabs)/family.tsx`, `apps/mobile/app/(tabs)/me.tsx`.
- Test: `apps/mobile/app/(tabs)/_layout.test.tsx`, `apps/mobile/app/(tabs)/desk.test.tsx`.

**Interfaces:**
- Consumes: `useSession`, `loadMyBookings`, `loadChildren`, `nextExam`, `deskTodos` and `countdown`.
- Produces: `tabsFor(role: "student" | "parent"): ("desk" | "family" | "timetable" | "bookings" | "me")[]`, giving `["desk", "timetable", "me"]` for students and `["family", "timetable", "bookings", "me"]` for parents.

- [ ] **Step 1: Write failing tests:**
  - the `tabsFor` values above;
  - the desk shows the exam-cover card with the Date, Start and Room boxes, and the countdown ticks each second;
  - with no bookings, the desk shows "No exams booked" with a link to Timetable;
  - Family with zero children shows "Add a child";
  - the selected child is remembered across restarts.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Build the screens:
  - iOS gets the native tab bar and Android the Material 3 bar, using expo-router `Tabs`;
  - the desk follows the "Exam desk" board;
  - Family has one folder tab per child.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(mobile): exam desk, family tabs and role tab bars`.

### Task 7: Offline candidate card and saved data

**Files:**
- Create: `apps/mobile/app/card/[studentId].tsx`, `apps/mobile/src/offline-cache.ts`, `apps/mobile/src/offline-banner.tsx`.
- Test: `apps/mobile/src/offline-cache.test.ts`, `apps/mobile/app/card/[studentId].test.tsx`.

**Interfaces:**
- Consumes: `onSignOut`, `loadMyBookings`, and the `student_details` read used by the web card page (`index_number` by `profile_id`).
- Produces: `cache.put(key: "card:" | "bookings", userId: string, value: unknown)`, `cache.get(key, userId): { value: unknown; savedAt: string } | null` and `cache.wipe(): Promise<void>`. Values are stored through `secureStorage` and namespaced by user id.
- Produces: `useOnline(): boolean` from NetInfo.

- [ ] **Step 1: Write failing tests:**
  - offline, the card renders from the cache, with a QR value exactly equal to the index number;
  - the banner reads "Offline. Showing what was saved at 09:12.";
  - `cache.get` for another user id returns null;
  - after `signOut`, `cache.get("card:", previousUser)` returns null;
  - offline, the Book button is disabled with "Booking needs signal".
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Build the card as on the candidate card board (tear line, mono index number, QR from react-native-qrcode-svg). Register `cache.wipe` with `onSignOut`. The photo is not cached in this plan.
- [ ] **Step 4:** Run the tests. Expected: PASS. Then put the iPhone in airplane mode and open the card.
- [ ] **Step 5:** Commit: `feat(mobile): offline candidate card and saved bookings`.

### Task 8: Pay with Stripe and deep links (needs Part 2 Task 11)

**Files:**
- Create: `apps/mobile/src/pay.ts`, `apps/mobile/app/booking/[id].tsx`.
- Create: `apps/web/public/.well-known/apple-app-site-association` and `apps/web/public/.well-known/assetlinks.json`.
- Modify: `apps/mobile/app.config.ts` (scheme `stemexamspace`, associated domain `stem-examspace.vercel.app`), `packages/shared/src/functions.ts` if Task 11 added a typed helper.
- Test: `apps/mobile/src/pay.test.ts`.

**Interfaces:**
- Consumes: the payment Edge Function from Part 2 Task 11. It takes a booking and returns a Stripe Checkout URL. Read its exact name and body from `supabase/functions` once Task 11 is merged.
- Produces: `pay(client, bookingId): Promise<"paid" | "held" | "expired" | { error: string }>`. It opens the Checkout URL with `WebBrowser.openAuthSessionAsync(url, "stemexamspace://booking/<id>")`. On return, or on the next app start, it reads the booking state from the database and polls every 2 s for up to 20 s while the state is still `awaiting_payment`, as the web success page does.

- [ ] **Step 1: Write failing tests:**
  - a dismissed browser with the booking still held returns `"held"` and the desk keeps its "Pay now" todo;
  - a booking turning `paid` during polling returns `"paid"`;
  - if the app is relaunched with a pending pay attempt saved, it re-reads the booking once;
  - `stemexamspace://booking/<id>` and `https://stem-examspace.vercel.app/account/bookings` both route to the booking screen.
- [ ] **Step 2:** Run the tests. Expected: FAIL.
- [ ] **Step 3:** Implement the flow. Add the home or centre choice here if Task 5 skipped it.
- [ ] **Step 4:** Run the tests. Expected: PASS. Then pay with Stripe test card `4242 4242 4242 4242` on the iPhone against L1 in Stripe test mode.
- [ ] **Step 5:** Commit: `feat(mobile): pay on Stripe and open links in the app`.

### Task 9: Device flows and store builds

**Files:**
- Create: `apps/mobile/.maestro/sign-in.yaml`, `book-and-pay.yaml`, `card-offline.yaml`, `add-child.yaml`.
- Create: `apps/mobile/eas.json` (profiles `development`, `preview`, `production`).
- Create: `apps/mobile/README.md` (how to run, the test project, and that store accounts belong to the institution).

- [ ] **Step 1:** Write the four Maestro flows from the spec's testing section, using test accounts read from the L1 project's seed file.
- [ ] **Step 2:** Run `maestro test apps/mobile/.maestro` against a `preview` build on the iPhone. Expected: 4 flows pass.
- [ ] **Step 3:** Repeat on an Android phone or emulator. Expected: 4 flows pass.
- [ ] **Step 4:** Commit: `test(mobile): device flows and EAS build profiles`. Store submission waits for the owner's Apple and Google accounts and the approved name and icon (spec §8).
