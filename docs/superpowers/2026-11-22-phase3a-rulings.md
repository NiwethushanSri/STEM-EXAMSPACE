# Phase 3A decisions made during the build

These are the choices the builder made without stopping to ask, in the order they were made. Each one says what it would cost if it turns out to be wrong. Nothing here has been deployed.

## Builder's calls in the plan (approved with the plan)

You approved these with the plan on 21 November. Any of them can still be changed.

- **Call 1** — Marking closes only when an admin closes it. The marking deadline never locks anyone out. It turns the dashboard and the marker's list red. *If wrong:* one condition in two places to make the deadline a hard stop.
- **Call 2** — Home scripts are handed out 24 hours after the family finishes, because they can still replace pages until then. Centre scripts go out as soon as they are verified and their no-code and unknown-code pages are settled. *If wrong:* home marking starts a day later than it could. Changing the wait is one constant.
- **Call 3** — "Next script" holds a piece for 2 hours, renewed by every save. A piece an admin assigned has no time limit. *If wrong:* a marker who stops mid-script keeps it for up to 2 hours. An assigned piece can sit until an admin notices (the dashboard shows it).
- **Call 4** — Changing a mark after submitting needs a short reason (3 to 300 characters). The marking stays submitted and every change is kept in a history. *If wrong:* one more box for the marker. Dropping the reason is one check.
- **Call 5** — "Name visible" takes the whole script back at once. Every piece goes on hold and the script returns to staff as "needs attention". The marker who pressed it is not offered that piece again, though an admin can assign it to them on purpose. *If wrong:* in a subject with one marker, an admin must assign the piece back by hand. Removing the exclusion is one condition.
- **Call 6** — Staff hand a taken-back script back with a "Hand back to markers" button. It never returns by itself. *If wrong:* one extra click per taken-back script.
- **Call 7** — Staff-confirmed pages are checked on the marking picture itself. The script is not verified until staff have looked at that picture and pressed "The name is hidden". The picture does not exist before staff accept the page, so this is the earliest it can be shown. *If wrong:* one more click per staff-confirmed page. Some Phase 2 tests need one more step.
- **Call 8** — Scans never add pages to a script that is being marked. The page is set aside, the lead marker and admins are told, and staff take the script back to place it. *If wrong:* a late page waits for a person.
- **Call 9** — Any change to a marking picture puts the script's taken and submitted pieces on hold, even if the new picture looks the same. The lead marker releases with one click. *If wrong:* a few needless holds after a hidden area is changed during marking (rare).
- **Call 10** — Allocation skips candidates linked to the marker as their tutor, and candidates with a declared conflict. Until accounts are linked in Phase 1B, the declared conflict is the working route. *If wrong:* nothing. Both checks sit in one place.
- **Call 11** — After the paper's structure is locked, an admin may change wording, points, guidance, pages and a question's maximum (not below a mark already given). They may also add a question. Removing a question, or changing groups or optional rules, is refused once marking has opened. *If wrong:* a wrongly entered question stays and is marked "no response". A real removal needs a small follow-up.
- **Call 12** — Marks can be whole or half marks, set per question. "No response" is a recorded answer, not a zero. *If wrong:* none expected.
- **Call 13** — Draft saves are not written to the audit log. Hand-out, submit, change after submit, give back, "Name visible" and every admin or lead action are. Draft saves are kept in a separate history. *If wrong:* the audit log would grow by thousands of rows per exam if every stroke had to be an audit row.
- **Call 14** — The demonstration marking pages are deleted and the mock admin marking page is replaced. The drawing tools are kept and reused. The real screens live at the marking page (markers and leads) and the admin marking page. *If wrong:* restore a demo page from the saved history.
- **Call 15** — On the page surface the pen draws, one finger scrolls, two fingers zoom, and a mouse draws. A "Draw with finger" switch (off by default) is for iPads without a Pencil. Touches while the pen is down, and for half a second after, are ignored. *If wrong:* the browser's own scrolling is not used there, so the scroll feel is ours to tune.
- **Call 16** — Emails queued while email was off are still sent when it is switched on. An admin can drop the waiting family emails first with one button and a reason. *If wrong:* a family may get a receipt days late if nobody presses the button.
- **Call 17** — The marking screen shows the index number, as the design says. A teacher who marks can also run their subject's register, where index numbers stand beside names. *If wrong:* one field to hide.
- **Call 18** — The mark scheme PDF has its own private storage area, separate from the paper files, so nothing built for papers can ever hand it to a family. *If wrong:* none expected.

## Before building

- **R1** — Adding a question after marking opens reopens pieces already submitted. Task 2 does this with its own direct changes, and Task 4 swaps in the shared step once it exists. *If wrong:* one small tidy-up in Task 4.
- **R2** — The marking area only checks that you may enter (corrector, teacher, admin or owner) and adds no side menu. The marking list brings its own staff frame. The page where a marker marks a piece is full-screen, as the design shows. *If wrong:* moving one wrapper.
- **R3** — Another local app was using the port the full browser tests need, so browser tests run against a stand-in server on a different port, as in Phase 2. The stand-in setup is not saved, and the full local browser run stays a job for you before release. *If wrong:* one run by you before release.
- **R4** — You approved the plan without choosing "script number only", so markers see the index number, as the design says. *If wrong:* hide one field on the marking screen and the lists, if you later ask.
- **R5** — The demo pages are deleted, but the old page viewer file stays for now, because the drawing stamps live in it until Task 12 moves them. *If wrong:* costs nothing.

## Task 0 — Family emails and uploads

- **R6** — The "leave this page?" warning stays whenever a file is waiting or uploading, as in Phase 2, as well as when a stored file is waiting to be sent. The earlier fix was about the closed window, not about dropping the upload warning. *If wrong:* one condition on the warning.

## Task 2 — Changing a paper's structure

- **R7** — Several small fixes made while the task was fresh. A mark save cannot slip in while a maximum is being lowered. A reopened piece goes back to its marker only if they are still approved, not blocked and active. Otherwise it returns to the pool. Re-ordering after opening is allowed. *If wrong:* a re-marker starts a reopened piece from scratch.

## Task 3 — Approving markers

- **R8** — When a marker is unapproved, or a conflict is declared, their unfinished marking on those pieces is set aside, as Task 2 does. If they are assigned the piece again later, that marking is revived. Two extra fixes: approvals count each script once, and a failed lead change is not shown as a success. *If wrong:* a revived marking row that should not exist.

## Task 4 — Opening marking and the minute check

- **R9** — One lock order is used everywhere: exam, then booking, then scripts in order, then pieces. This stops two actions waiting on each other. The internal helper functions are also shut to the outside, as in Phase 2. *If wrong:* costs nothing.

## Task 5 — Handing out pieces

- **R10** — Three problems found in review are fixed. Resuming a piece now respects "marker saw the name". A conflict declared during a hand-out can no longer leave the marker holding the piece. Handing out many pieces at once is rebuilt to be fast, with a timing test. *If wrong:* a "try again" message instead of a stuck lock.

## Task 6 — Opening, saving and submitting

- **R11** — After marking closes, a submitted piece opens read-only without its pictures. Privacy comes first, and nothing can change after close anyway. *If wrong:* a marker cannot see the page when re-reading a closed piece.
- **R12** — Accepted risk. The storage service checks permission only when a picture link is made. A marker could make a long-lived link to a name-hidden picture while holding the piece. The 2-minute limit is the app's own choice. The pictures carry no name. The fix is recorded for later. *If wrong:* a former holder keeps access to a name-hidden picture.
- **R13** — Several smaller fixes bring the save and submit steps up to the privacy standard. They cover submit returning the new version, safer error handling, correct best-of totals for optional groups, refusing a page outside the piece, and more tests. *If wrong:* a small fix round.

## Task 7 — Taking scripts back and name reports

- **R14** — If a script has a missing picture, every piece of it is held, not just the taken ones. A hold now only happens when what the picture hides has really changed, with one grouped email per exam and kind. A new "Release all" is added. "Name visible" now bars the reporter from every piece of that script. *If wrong:* an extra stored column and a grouped email.
- **R15** — A marker barred after seeing a name is treated like a blocked marker when pages are refreshed. A lead who is blocked for that candidate cannot release holds either. Release all locks and re-reads the right scripts first. *If wrong:* a small round of fixes.

## Task 8 — Checking marking pictures

- **R16** — Staff must check a new marking picture before a script is released, even when the script is being marked. "The name is hidden" works only once the picture has loaded. "A name still shows" bars every live marker of that script. The wording and the "200+" count are tidied. Marker links last 2 minutes, staff screens 5. *If wrong:* one small round.
- **R17** — While a picture waits for a check, no piece of that script is handed out. "A name still shows" on a taken-back script also bars the live markers. Each hold reason gets a sentence on screen. *If wrong:* one small round.

## Task 10 — Staff and marker lists

- **R18** — The alerts list now sends the reason a hold cannot be released, and the screen shows a sentence for each. This adds one small database change. The Task 13 dashboard change is renumbered after it. *If wrong:* a renumber in Task 13's plan.

## Task 11 — Saving rules for the marking screen

- **R19** — Only network and server faults are retried. Any other refusal stops saving and keeps the work, so the screen can tell the marker. A change after submit carries its reason. The marker can discard unsaved changes. A question with no mark and no "no response" counts as missing, as the server does. *If wrong:* one small round.

## Task 12 — The marking screen

- **R20** — Nothing can be pressed while Submit runs, so no change is lost. Questions over 9 marks always show the number box. "Next script" works after Submit. Covers show no pictures. Pictures are signed when shown. Escape closes the drawer. A browser test covers the submit race. *If wrong:* one round.
- **R21** — Typing a digit replaces the mark in the box instead of adding to it, so "1" then "5" cannot become 15 by mistake. The drawer closes on wide screens. "Name visible" is off under a cover. The Marking link saves first. *If wrong:* a small round.

## Final review

- **R22** — One fix wave covers the final review. Markers can no longer read stored mark scheme PDFs before marking opens. The alerts list is rebuilt to be fast, with a per-exam "Release all" on the progress card. Two-session browser tests are added. Nine smaller items are fixed. Two are left for 3B. *If wrong:* a little more code in one wave.
- **R23** — Two timing items are not fixed now and become the first items of the Phase 3B plan. The speed test limit would rise from 2 to 4 seconds, and the 1-minute check has no slack. The minute job's log keeps the exam id, which is not personal data. *If wrong:* a slow test run may fail once, and a withdrawn page may stay on screen for about 2 minutes instead of 1.
- **R24** — The build's working folder (ledger, briefs, reports) is kept after the clean review until you pick how to finish the branch. It holds the smaller items put off for later. The decisions are also written in this file. *If wrong:* a few megabytes of disk, not saved to the shared history.
- **R25** — On this low-memory computer, two speed tests sometimes failed in a full run, although each passed alone. Earlier tests left the database's planning figures out of date. The two tests now refresh those figures for their own data first, and their limits leave more room while still staying well inside the website's 8-second limit. Only test files changed. The full run then passed three times in a row. *If wrong:* nothing in the product; a much slower test would still be caught.

18 builder's calls and 25 rulings.
