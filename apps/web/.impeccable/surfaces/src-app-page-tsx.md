---
version: 1
slug: "src-app-page-tsx"
primary_target: "src/app/page.tsx"
related_targets: ["src/components/home"]
---

# Public home page

Scope: the public home page (`/`). Visitor mode: Persuade. Audience: parents deciding and paying, and students aged about 14 to 18 sitting GCSE and A level mocks. Job: understand what is on, when, where, the price and seats left, and book a seat; trust the marking. Proof on hand: the live timetable (`exams_public`, seats left), the exam-day process, the index card, on-screen marking. Constraints: GCSE and A level only on the page (no 11+, TMUA, FSAT or UCAT); logo used exactly; no invented statistics, testimonials, ratings or photos; build is code-led (no image generation).

History: four themed directions were declined; the user chose to mirror Save My Exams' visual language. A premium navy-and-serif version was then tried and the owner went back to this one; further work is small refinements.

## Direction contract

THESIS: A bright, friendly, trustworthy education site in the manner of Save My Exams: the hero says what we are and routes parents, students and visitors through three role cards; the rest proves it with the live paper finder, how marking works (an interactive marking screen) and the index card. It refuses invented social proof (no ratings, reviews or press logos) and any copy or asset of the reference site.

OWN-WORLD: White and soft grey (#F7F8FA) bands; one family, Plus Jakarta Sans, 800 headings and 18px body; logo navy #10224F for headings, logo blue #1F64AE for every action; emblem tints (green, teal, orange, blue) for icon tiles, subject chips and seat pills; fully rounded pill buttons and chips; 16 to 18px rounded bordered cards with a soft navy-tinted shadow; a hand-drawn blue ring around one word per section heading; navy line drawings with people above the three steps; blue tick circles for lists.

STORY: A parent sees the next real paper in the hero badge with a countdown and books, or picks their role; anyone sees how it works in three steps, filters the upcoming papers with seats left and prices, tries the marking screen and sees what comes back, meets the index card, reads what each side gets and the honest answers, and closes on "Sit it before it counts".

FIRST VIEWPORT: White sticky header (exact logo left, Timetable / How it works / Marking, Sign in, blue pill Book a seat; a scrolling section menu under it on iPad portrait and phones). Hero on a faint blue wash: live badge ("Next paper: GCSE Maths, Sat 5 Jun · in 202 days" or "dates coming soon"), two-line navy headline "Real mock exams, marked like the real thing", one paragraph, blue pill Book a seat plus an underlined link; right column, three role cards (parent, student, just looking) with tinted icon tiles and arrows. The soft grey How it works band starts at the fold.

SIGNATURE INTERACTION: live data and hands-on proof: the paper finder filters the timetable on the page; the marking screen answers taps and switches to "What you get back"; the hand-drawn rings and step drawings draw themselves as they scroll in (CSS only, none under reduced motion).

FORM: Category standard, mirrored from Save My Exams at the user's request, kept after a premium alternative was declined. seed:6543903cf79c2db3

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
