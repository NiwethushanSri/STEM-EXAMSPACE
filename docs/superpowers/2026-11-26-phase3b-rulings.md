# Phase 3B decisions made during the build

These are the choices the builder made without stopping to ask, in the order they were made. Each one says what it would cost if it turns out to be wrong. Nothing here has been deployed.

## Builder's calls in the plan (approved with the plan)

You approved these with the plan. Any of them can still be changed.

- **Call 1** — The second marker is any other approved marker of the subject, the lead included, who is cleared and not paused. It is never the first marker, never someone with a conflict or tutor link for the candidate, and never someone who saw a name on the script. A marker cannot tell a second marking from a first. *If wrong:* showing "Second marking" on the piece is one field.
- **Call 2** — The sample for second marking is drawn per piece (a whole script, or one question group of it). Whether a piece is in the sample is decided once, when its first marking is submitted. The lead or an admin can add pieces by hand or drop a waiting one with a reason. *If wrong:* a small exam may get no second marking by chance. The approval page shows how many were second-marked.
- **Call 3** — Two markings are "outside tolerance" when the totals differ by more than the exam's percentage of the maximum, or any question does, with a floor of one mark. "No response" against 0 agrees; "no response" against any mark above 0 always goes to the lead. Half marks are compared exactly. *If wrong:* the floor is one constant.
- **Call 4** — Within tolerance the first marks stand. Nothing is averaged. *If wrong:* averaging is one branch.
- **Call 5** — A practice or seeded script is a frozen copy of the lead's own marking of a piece. The candidate's real marks are never touched by it. At most 10 of each per exam (and per question group). *If wrong:* letting an admin pick another marker's piece is one condition.
- **Call 6** — Seeds come only through "Next script", about one in every 10 pieces (set per exam, 3 to 50). Inside tolerance the marker is told nothing. Outside, they see the lead's marks beside their own. *If wrong:* a marker who only works on assigned pieces meets no seeds.
- **Call 7** — Three missed seeds in a row pause the marker on that exam only. Their holds end and their scripts go to the lead within a minute. *If wrong:* pausing across the whole subject is one condition.
- **Call 8** — When a marker is paused, every piece they submitted on that exam that the lead has not reviewed goes to the lead, including pieces already checked. Their second markings are set aside. *If wrong:* more review work for the lead after a pause.
- **Call 9** — Practice is announced on screen. A marker does every practice script, sees the differences, then waits for the lead to clear them by hand. *If wrong:* a slow lead holds markers up.
- **Call 10** — Double marking, seeds and practice can be turned off only while the subject has at most one approved marker, with a reason. Opening marking with double marking on needs two approved markers; with seeds or practice on it needs a lead. *If wrong:* a two-marker subject where one falls ill must unapprove them first.
- **Call 11** — An admin may do everything the lead does in review. A lead who is one of the two markers may settle the difference; the approval page counts those. *If wrong:* a stricter rule is one check.
- **Call 12** — "Send back" goes either to the same marker (with a note) or to another marker (the first marking is set aside). *If wrong:* one more choice on the box.
- **Call 13** — Final marks have their own table. Only the marker changes their own marks; the lead changes the final mark, with who, when and why, until the exam is approved. *If wrong:* none expected.
- **Call 14** — A piece is "checked" when nothing waits on it. It stops being checked when it is taken back, sent back, reopened or changed, and is checked again at once. Once the lead settles a piece, its markers can no longer change it. *If wrong:* a marker who spots a slip after a settle must ask the lead.
- **Call 15** — Approving closes marking and freezes everything until an admin withdraws the approval with a reason. A script that turns up after approval is flagged, never added silently. *If wrong:* one more step to fix something late.
- **Call 16** — Marker statistics are per piece. Three neutral "Worth a look" notes appear from 10 pieces, for the lead and admins only. *If wrong:* the thresholds are three constants.
- **Call 17** — Pay is one rate per script (or per question group), the same for first and second marking. Practice and seeds are never paid. Work taken away is not paid. The month is the UK calendar month of submission. The lead's review work is not paid by the system. *If wrong:* a marker loses pay for a piece taken away through no fault of theirs; an admin settles that by hand.
- **Call 18** — An admin fixes a month's statements after the month ends. Fixed statements never change; a late piece goes into the next month. Markers have no payments page. *If wrong:* a page for markers is one function and one list.
- **Call 19** — Picture links are signed on the server. Markers no longer receive picture file paths at all. *If wrong:* one more network step per screen.
- **Call 20** — No email for a difference or a sample review. One email, with no name in it, goes to the lead and admins when a marker is paused. *If wrong:* a lead who never opens the page misses work.
- **Call 21** — The last demonstration pages (`/examiner` and `/examiner/standardisation`) are deleted. *If wrong:* restore them from the saved history.

## Before building

- **R1** — You approved the plan without answering its five questions, so the defaults stand. Second marking is paid at the first-marking rate, and lead review is unpaid. Work taken away is not paid. Markers see no statements or statistics. The checks can be switched off only with at most one approved marker. The lead clears practice by hand. *If wrong:* a small change each.
- **R2** — As in Phase 3A, nothing on the other local app's port is touched. Browser tests run on a stand-in server, and the full local browser run stays a job for you before release. *If wrong:* one run by you before release.

## Task 1 — Picture links signed on the server

- **R3** — Several small fixes from review. Tests that passed whatever the code did are rewritten. The page viewer keeps keyboard focus inside it and says when a page has no marking picture yet. The local browser run starts the server functions it needs. *If wrong:* one small round.
- **R4** — Clearing out old test containers now removes only this project's container, never one belonging to your other local project. *If wrong:* costs nothing.

## Task 2 — Check settings

- **R5** — A lead sees who turned a check off and when, but not the reason; admins see the reason. Turning a check on after marking opens follows the same two-marker and lead rules as opening. *If wrong:* one small round.

## Task 3 — Handing out second markings

- **R6** — A second marking whose hold ran out can be taken by another marker; the old unfinished marking is set aside. Second markers do not see the first total. *If wrong:* one round.
- **R7** — Blind second marking is a hard rule. Anyone who is not an admin gets no first total, times or marker name on a piece waiting for a second marking, or on a piece they are second-marking. The lead's review screen shows both markings on purpose. *If wrong:* one small round.
- **R8** — A search filter that could have hinted at who first-marked a piece is closed. *If wrong:* one line.

## Task 4 — The check itself

- **R9** — A lead's review settles only the submission it reviewed. If the first marking is reopened and resubmitted, it is compared again. Withdrawn and void scripts are skipped. *If wrong:* one round.

## Task 5 — Practice and seeded scripts

- **R10** — "Left to mark" counts every piece "Next script" could still hand out, seeds included. This means the count reaches 0 exactly when "Next script" says nothing is left. The cost to you: once real work runs out, a marker pressing "Next script" is given their remaining seeded scripts (up to 10 per group), which are not paid. *If wrong:* a marker does a few unpaid seeds at the end.
- **R11** — Turning seeds or practice off retires their open practice and seeded scripts. *If wrong:* one small change.

## Task 6 — What the marker sees

- **R12** — If the server refuses a save, the screen puts back the last saved marks and says why. It never says "Saved". *If wrong:* a few lines.
- **R13** — An older Phase 3A browser test now clears its marker through the lead first, as a real exam would. *If wrong:* a few lines in one test.

## Task 7 — Lead review

- **R14** — On a piece the lead or an admin has reviewed, that lead or admin is never offered its second marking, because review shows them the marks. *If wrong:* a slightly smaller pool of second markers.
- **R15** — Accepting a paused marker's scripts ends any unfinished second marking on them; it is not paid. A submitted second marking stands and is paid. *If wrong:* a second marker loses unfinished work (rare).
- **R16** — Small fixes from review, including a speed test on the review list with 500 open reviews. *If wrong:* one round.

## Task 8 — The lead's pages

- **R17** — "Change a final mark" on a script that is not yet checked first accepts it, then sets the mark. If the second step is refused, the page says the script was accepted but the mark not changed. *If wrong:* a rare half-done change the lead can repeat.
- **R18** — A lead sees "Ask an admin to assign one or release them" for scripts stuck waiting for a second marker. Letting a lead release or assign them is new work, left for you to decide. *If wrong:* the lead must ask an admin.

## Task 9 — Marker statistics

- **R19** — "Sent back" counts every time a marker's work was sent back, from the record each send-back leaves. *If wrong:* a figure that slightly undercounts.
- **R20** — A seed counts as hit or missed by what was recorded when it was submitted, so the statistics agree with the pause rule even if tolerance changes later. *If wrong:* a speed test may fail when memory is low.
- **R21** — One speed test's limit rises from 4 to 6 seconds, still inside the website's 8-second limit. *If wrong:* a 50% slowdown would pass unnoticed until near 6 seconds.

## Task 10 — Approving an exam's marking

- **R22** — "Name visible" still works on an approved exam, because privacy comes before the freeze. Any problem after approval marks the approval out of date, with "A script arrived or changed after this approval. Withdraw the approval to include it." Phase 4 must refuse to prepare results while an approval is out of date. *If wrong:* one round.
- **R23** — One shared rule decides whether two markings were compared and whether they agreed, so the approval page and the statistics always give the same answer. *If wrong:* a figure changes meaning if tolerance changes.
- **R24** — A timing edge case on paused markers is closed and tested. *If wrong:* one round.

## Task 11 — Marker pay

- **R25** — Fixed statements cannot be changed by anyone, not even the server's own key, and each one is checked to add up when it is fixed. Months must be fixed in order. A fixed statement shows the exam's current title. *If wrong:* a fix is permanent, so this errs on the strict side.

## Task 12 — Payments pages

- **R26** — Pound amounts like "0,500" are refused. After saving, the box shows the stored amount. Every CSV download is recorded, and none leaves without its record. *If wrong:* one round.

## Final review

- **R27** — Exams already being marked when 3B goes in have double marking, seeds and practice turned off, with the reason "Marked before the checks existed". Scripts already marked are checked on their first marks. Without this, those exams could never be approved. Nothing is being marked live today, so this changes no real data now. *If wrong:* an admin turns double marking back on for that exam, with a reason.
- **R28** — The admin home tests only the exams it lists for a late script after approval: those closed within 14 days or not yet approved. *If wrong:* a late script on an old approved exam shows on its approval page and is refused by Phase 4, but raises no alert on the home.
- **R29** — Open sample reviews of an approved exam are hidden from the lead's list. They come back if the approval is withdrawn. *If wrong:* hidden rows nobody sees until then.
- **R30** — Wherever a figure is labelled "scripts", it counts scripts. Pay keeps its own word. *If wrong:* on an exam marked by question group, figures and the review list differ.
- **R31** — Every speed test keeps its limit. They are trusted only when this computer has at least 2 GB of memory free. Before deploy, one full database test run must pass with 2 GB free. *If wrong:* a slow function is caught at that run instead of earlier.
- **R32** — Two small items are left as they are: the minute job's lock order (the cost is one rare failed admin action that works on retry) and a few small test gaps that hide no known fault. *If wrong:* a rare retry.
- **R33** — The check of the fixes found that, on an exam marked by question, the home now counted scripts while the approval and Review pages still counted pieces. The same thing could read "1 script" on one page and "2 scripts" on another. This was fixed straight away, with tests. *If wrong:* one small extra change.
- **R34** — Migration 012 turns the checks off on every exam already being marked. It cannot tell an exam opened under 3A from one opened under 3B. That is safe because all the 3B migrations go in together in one push, and the release notes now say never to split them. *If wrong:* on a test copy, an admin turns the checks back on with a reason.
- **R35** — Three things are written into the release notes rather than changed. A former lead who opened a review but never closed it can still be offered that script's second marking. On an exam marked by question, a few figures count question groups, not whole scripts. Phase 4 must count its new "final" state as checked on the home page. *If wrong:* wording only.

## Still yours to decide

- Whether markers should see the index number on the marking screen (it shows today, as the design says).
- The five defaults in R1.
- Whether a lead may release or assign scripts stuck waiting for a second marker (R18).
- The date of the first exam.

21 builder's calls and 35 rulings.
