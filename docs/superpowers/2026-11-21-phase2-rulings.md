# Phase 2 decisions made during the build

These are the choices the builder made without stopping to ask, in the order they were made. Each one says what it would cost if it turns out to be wrong. Where the build record gave no cost, the cost is a short estimate and is marked "(estimate)". Nothing here has been deployed.

## Before building

- **R1** — When staff confirm a blank page or place a page, the booking's latest home submission is checked again, so it can become "received" on its own. Otherwise those two actions would leave the submission stuck. *If wrong:* a small rework of one function.
- **R2** — The processing server deletes draft uploads that were never submitted, once they are over an hour old. Originals that were submitted are never deleted. This closes a gap where nothing was assigned to do the clean-up. *If wrong:* one extra pair of functions to remove.
- **R3** — Notices to staff and families are queued automatically when a submission changes state or an exception is raised. That leaves the earlier code untouched. *If wrong:* the automatic triggers would need rewriting.
- **R4** — Home-exam rules and materials are saved by their own new action, not by changing the existing "save exam" action. It would otherwise mean reworking many existing tests. *If wrong:* one more server action to fold in.
- **R5** — The local browser test script starts the processing server before the tests and stops it afterwards, so the tests can run end to end. *If wrong:* costs nothing.

## Task 0 — Processing server set-up

- **R6** — An image-handling library with a "lesser" open-source licence is allowed, because only GPL-type licences are banned and the server is run, not handed out. *If wrong:* a fallback where families send JPEG photos instead of iPhone HEIC photos.

## Task 1 — Paper page set-up

- **R7** — Staff draw the "hide the name" areas on a sample copy of the paper, with a made-up candidate called "Sample candidate". Papers are set up before any booking exists, so a real copy is not available. It makes no copy record and no download log. The page layout matches every real copy. *If wrong:* a small change to the paper-copy service and its tests.

## Task 2 — Job queue and upload records

- **R8** — A job can only be finished or recorded by the worker that holds it, on the attempt it holds. A late worker cannot overwrite a live run. A "still working" signal keeps the hold alive. *If wrong:* a change to the signature in Task 4.
- **R9** — If a "re-hide the name" job fails, the upload itself is not marked failed. An upload that was already processed should not look broken. *If wrong:* costs nothing.
- **R10** — The queue tests no longer assume an empty local database. They only count their own test data. Later browser tests leave jobs behind, which would otherwise break them. *If wrong:* (estimate) a few tests to loosen again.
- **R11** — One upload can only have one waiting or running job of each kind. This stops it being processed twice at once, and the later "process again" button relies on it. *If wrong:* (estimate) one database index to remove.
- **R12** — The upload shows "processing" as soon as its job is picked up, "processed" when finished, and "failed" if the last attempt fails. Nobody was setting "processing" before. *If wrong:* (estimate) a small change to one function.

## Task 3 — Picture processing and name hiding

- **R13** — The picture used for marking has the name band and hidden areas painted white, positioned from where the page's code sits compared with where it was printed. If the print is too small or too far off, no marking picture is made and the page is flagged for a retake. A visible name breaks the first anti-goal. *If wrong:* a little extra white margin on pages printed at actual size.
- **R14** — For home PDFs where the code is not near its printed place, the system tries to find the page edges and straighten it first. This covers PDFs made from uncropped phone photos. *If wrong:* one extra attempt per such page.
- **R15** — Light backgrounds, such as a white desk, are tested. If no page edges are found, the page is placed from its code, and flagged only if it would run off the photo. *If wrong:* a fallback path to remove.
- **Unnumbered** — A page placed by its code alone, with no paper edges found, is flagged and gets no marking picture. The code alone cannot follow a tilted photo, so this is the safe choice. *If wrong:* (estimate) some extra retake requests for photos with faint edges.
- **Unnumbered** — The 15 mm limit means a page printed centred below about 90% size is flagged. Families are told to print at 100%. *If wrong:* (estimate) some families with scaled-down prints are asked to retake.
- **R16** — A flagged page is treated like any other quality problem. At home, the family is asked to retake it, or can choose "Send as it is", which raises an alert for staff. At a centre, any flagged page raises an alert for staff. *If wrong:* (estimate) wording and flow changes in the upload screen and the staff queue.
- **R17** — Staff can draw hidden areas on one individual page, in the exception queue, to fix a flagged page. Without this, such a page could never be marked. *If wrong:* a small table, one function and one extra input to the re-hide step.
- **R18** — Name hiding now measures the page itself. It finds the two long printed rules on the page and fits the page's true shape from them and the code. If the rules are not clearly found, no marking picture is made and the page is flagged. The earlier method guessed from the small code alone. *If wrong:* some extra flags on badly printed pages.
- **R19** — Pages are never stretched unevenly by more than half a percent. Home PDFs also try to find the paper edges, and very large images are refused before they are opened. *If wrong:* (estimate) a few more pages flagged for retake.
- **R20** — The image library is swapped for a decode-only version, because the first one bundled a GPL-licensed encoder. This keeps the "no GPL" rule. *If wrong:* an image rebuild.
- **Unnumbered** — The top printed rule must have the page's identity-line ink above both ends. This rejects shadows mistaken for the rule. It is stricter, and fails safe. *If wrong:* (estimate) a few more retakes on shadowy photos.
- **Unnumbered** — A very blurry page now also counts as a flagged page, so the family is asked to retake it. *If wrong:* (estimate) some blurry-but-readable pages need a second photo.
- **Unnumbered** — A tiny 583-byte HEIC test file is committed to the project, because the new library cannot create one. *If wrong:* (estimate) one small file to remove.
- **R21** — The top rule's position is checked on its own against a prediction from the code and the bottom rule. If another similar line is nearby, the page is flagged. A privacy check should not rely on the fit it is checking. *If wrong:* retakes for photos where another copy page shows above.
- **Unnumbered** — The bottom rule must also match its predicted place, and a page edge on the photo border is rejected. Full-frame tilted photos on a white table are now flagged. This puts privacy first. *If wrong:* (estimate) more retakes for such photos.
- **R22** — The two long printed rules must together form the printed rectangle, within tight limits of length, angle and spacing. Any second similar line nearby makes the page ambiguous and flagged. This replaces chasing single cases one by one. *If wrong:* (estimate) more pages flagged for retake on scans that are slightly stretched.
- **Unnumbered** — A competing line only counts if it is at least 0.6 as dark as the real rule. Photos of a page lying on a pile are always flagged. *If wrong:* (estimate) a few legitimate pages flagged, and some real piles not caught.
- **R23** — An extra check compares the vertical and horizontal scale of the code. This catches a page squashed by a pile's outline, where the name had been showing. *If wrong:* (estimate) more clean photos flagged for retake.
- **Unnumbered** — About one in 24 clean test photos is flagged for a safe retake by R23, and the margin for the code's shape check is thin. These limits are to be tuned on real files. The commit note names the model that wrote it. *If wrong:* (estimate) retakes until tuned.
- **Unnumbered** — Parked, not fixed: a page curled or unevenly squashed on a 10–14 mm pile can still let a lower sheet's rule be chosen, and the name may show. Another check might flag every page of some real papers, so real papers must decide. Families are told to photograph each page flat, alone, on a dark surface. *If wrong:* a name could show on such a photo; the fix is a second printed marker (a layout change).

## Task 4 — Recording pages

- **Unnumbered** — When a file fails for good, the home submission is rebuilt from its other uploads and checked again. Replaced pages are kept, marked as replaced, rather than deleted. A page placed by a code and a "poor quality" alert mean "Send as it is" at home. *If wrong:* (estimate) later tasks that forget to ignore replaced pages would show wrong pages.
- **R24** — A failed home file holds the script. Re-running keeps a family's "Send as it is" alert. Sorting puts unknown sharpness last. An unexpected error no longer stops the worker. *If wrong:* (estimate) a few small fixes in the record function.

## Task 5 — Exam setup screens

- **R25** — Screen readers announce phase changes and the confirmation on the exam-day screen. Saving home rules with no change writes nothing and no audit row. Exam day is critical. *If wrong:* (estimate) a small accessibility change to undo.

## Task 6 — Family upload

- **Unnumbered** — Family wording and checks sit in a separate helper file. The upload screen is about 480 lines, which the final review judges. Submitting raises one "late" alert per booking and marks the script late. Staff decide in Task 10. *If wrong:* (estimate) a file split or a flow change.
- **R26** — Exam-day reliability fixes: phone memory use is kept low, "Try again" does not upload twice, tus uses a fresh sign-in each time, never-submitted draft uploads are cleared after the late window plus a day, the camera window traps focus, and several tests were added. *If wrong:* (estimate) a few small fixes to revisit.
- **Unnumbered** — No browser-style test library is used. Logic is tested in plain functions, and the browser checks come in Task 12. Blur checks run one at a time. *If wrong:* (estimate) screen bugs found later in the browser checks.

## Task 7 — Notices

- **R27** — Notices survive when a re-run deletes their alert, so a sent alert is not re-sent. The time budget is checked before starting a notice. Notices given up after three tries are counted. Rejected and "needs attention" notices go out once per submission. *If wrong:* (estimate) a few duplicate or missed emails.

## Task 9 — Centre scanning

- **R28** — A candidate is not complete if their pages come from more than one paper version. A centre cannot be completed while any paid candidate is unmarked on the register. A missing paper creates a "missing pages" alert. "Complete" resets on any new version. Totals count open alerts only. The screen also gets safer polling and clearer labels. *If wrong:* (estimate) wording and counting changes.
- **R29** — The register check ignores bookings with no student. The completion reset runs when a version changes in either direction, and only for centre scripts not yet past verification. Button names start with their visible text. *If wrong:* (estimate) small fixes to one trigger and some labels.

## Task 10 — Exception queue

- **R30** — Staff actions on exceptions are tightened. A late upload is set aside when on-time pages exist, otherwise the script is void. Pages can only move within the same family or a sibling. Confirming a flagged page needs a hidden area or an explicit "no name on this page". *If wrong:* (estimate) staff may need a looser rule for some edge cases.
- **Unnumbered** — The lock on scripts past verification is enforced in the staff writer, not the version writer, because earlier tests rely on scans adding versions. Phase 3 must decide whether scans may still add pages. A rejected late upload still emails "Rejected" even when on-time pages are used. *If wrong:* (estimate) a confusing email, and a Phase 3 decision.

## Task 11 — Staff re-checks and re-hiding names

- **R31** — A page with no code that staff place or confirm needs the same name check as flagged pages, so extra sheets can be marked. If a re-hide step cannot prove a page that had a safe picture, the old picture is removed and staff are alerted. *If wrong:* (estimate) staff do a little more checking.
- **R32** — A staff confirmation only counts while the page is in the same rotation and with the same areas. A page that once had a safe picture is never given a plain fallback band. A permanent failure removes the pictures and alerts staff. A turned page needs a fresh name check. *If wrong:* (estimate) extra staff work after turning or re-processing a page.
- **Unnumbered** — Alerts raised by re-hiding close themselves once a picture is made. A failure clears every answer page of the file, which is safe. Some pages regain a picture only by turning upright or processing again. The processor must be deployed with migrations 059 to 061. *If wrong:* (estimate) a deploy-order mistake would refuse the old picture folder.
- **R33** — Only the latest name check on a page counts, and "name visible" cancels earlier "no name" ticks. A reprocess must not leave staff-placed pages exposed or lost. Extra family pages are kept. Locked scripts refuse area changes. *If wrong:* (estimate) a few more refusals that staff must work around.
- **Unnumbered** — Parked as a known limit: if staff confirm a code-less page and their area misses a name written along the side, the name shows, because staff confirmation is the only control. A preview and a "Name visible" button come in Phase 3. *If wrong:* a name could be exposed to a marker.
- **R34** — After any re-run, a page that staff had touched gets no picture until its name is re-checked, and no script may link to a replaced page. Carrying links across is only done onto a page with no booking of its own. *If wrong:* (estimate) extra re-checks after a re-run, privacy first.
- **Unnumbered** — Accepted side effects: duplicate noise when another file is reprocessed, "missing pages" notices cleared at the next check, and extra re-checks after a reprocess. *If wrong:* (estimate) a little more staff clean-up.
- **R35** — "Process again" is refused when staff have already worked on pages of that file. The screen explains why. A script past verification never gets a new page version from the processor. *If wrong:* (estimate) staff cannot re-run a touched file and must ask for a new upload.
- **Unnumbered** — Turning a page alone does not stop a re-run. A "staff-raised check" means a "name visible" check or an open "reprocessed" alert. Withdrawn and void scripts are not treated as being marked. *If wrong:* (estimate) a few odd cases to adjust.
- **R36** — A page placed by staff is not silently displaced by a later scan of the same slot. The incoming page raises a duplicate alert. The detail screen says whether a file can be reprocessed. *If wrong:* (estimate) more duplicate alerts for staff.
- **R37** — The last fix round locks page rows in a fixed order, so a save and a re-run cannot clash. A page can never sit in two scripts. Families cannot submit once their script is past verification: "Your answers are already being marked." Orphaned pictures are deleted. *If wrong:* (estimate) a few legitimate late changes refused.
- **R38** — Before a re-run, scripts it restores give up pages that another script's current staff-owned version shows. A duplicate is never deleted unless it is where staff put it. *If wrong:* (estimate) more cases for staff to settle by hand.
- **Unnumbered** — Parked: two rare lock clashes can make staff see "try again" or make a job retry. Nothing is corrupted. Noted in the release notes. *If wrong:* an occasional "please try again".
- **Unnumbered** — Parked: void or withdrawn scripts still count as holding a page. This is harmless, since staff dismiss the claimant's alerts. *If wrong:* some extra alerts to dismiss.
- **Unnumbered** — Parked for Phase 3: a re-hide can change or remove a marking picture while a script is being marked. Phase 3 must hold the piece and tell the lead. *If wrong:* a marker could meet a changing picture until Phase 3 handles it.

## Task 12 — Browser tests and release checks

- **R39** — The sweep before a re-run drops shared links quietly, then raises "missing pages" only for slots still not shown. Failed-job counts use open alerts only. Jobs stuck over 15 minutes count as stuck. Release-note wording and known limits were added. *If wrong:* (estimate) a few counts or alerts wrong on the dashboard.

## Final review

- **R40** — One fix wave covers the critical name leak on a flagged, coded page, six important issues (timeouts, draft visibility, page roles, redeploying the paper-copy service, shutdown signal, staff email volume) and the cheap minors. Some items are deferred: superseded pictures in storage, a lost finish after a recorded result, teachers recording "scanned" custody, a "same area for all flagged pages" helper, and a full rewrite of the slow function. *If wrong:* a large centre still needs smaller scan files (documented), and staff draw one area per fit-to-page page.
- **R41** — Commit notes in the fix wave name "Claude Fable 5.2", the model that wrote them. Nothing is pushed, so a reword stays cheap. *If wrong:* one rebase reword before pushing, if the owner wants a single trailer.
- **R42** — The last check of the fixes found seven small problems, none of which shows a name or loses a page. They are not fixed in another round. Two get notes for the owner and staff, and five become the first items of the next build ("Small fixes before launch" in the release notes). *If wrong:* until those fixes land, a family may get a "paper released" email they cannot use yet, and a late family sees a confusing "Press Submit".
- **R43** — The build's working notes are kept on this computer after the clean review instead of being deleted. They hold small deferred items that are written down nowhere else. *If wrong:* a few megabytes of disk space.

43 numbered and 20 unnumbered decisions.
