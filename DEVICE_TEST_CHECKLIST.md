# Commit 2.6.0 – device test checklist (UI/UX redesign)

Install: pause Play Protect scanning, tap the APK, choose **Update**, re-enable scanning.
Payments are NOT connected in this build. Nothing can be charged.

## A. First look
1. Open Commit. Home says "Ready for a fresh start?" with one **Start a challenge** button and an Explore list (History, How Commit works, Settings). No ₹ anywhere on Home.
2. Settings → Blocking setup: 5 rows, all "On". "What Commit can see" card is readable.
3. Settings → How Commit works: six cards, easy to understand.
4. Settings → Payment screens: says "Design preview … No payment is being made."

## B. Create a challenge (use 5 min, YouTube, 1 use × 2 min, ₹100)
5. Step 1: question "Which apps do you want to stay away from?", search works, button says "Continue · 1 app".
6. Step 2: pick 5 min; "Ends …" time appears above Continue. Try Custom duration.
7. Step 3: "Allow emergency access?"; the green card changes as you pick.
8. Step 4: ₹100, ₹500, ₹1,000, ₹2,500, ₹5,000, ₹10,000 + Custom. In Custom, 99 and 10001 are refused; 750 is accepted.
9. Step 5: summary is correct; button says "Tick the box to start" until you tick; then "Start challenge".

## C. During the challenge
10. Challenge screen: time left without seconds (e.g. "4 min", then "Under 1 min"), "You're doing it.", protected apps, ₹100, "1 of 1 left" — all visible without scrolling.
11. Open YouTube → blocked; Commit shows "You're in a challenge." / "YouTube is blocked for …". Video/audio does not keep playing.
12. "Back to challenge" opens the challenge screen. "Back to home" returns Home; Home says "You're doing great." with the time remaining, a progress bar and **Continue challenge**. No ₹ on Home.
12a. On Home during the challenge open History, How Commit works and Settings – all open normally.
12b. Tap "New challenge" in Explore: you see "You already have a challenge in progress." and cannot start a second one. "Open challenge" takes you back.
13. Emergency access → "Use emergency access?" shows Free / does not end your challenge → use it. Ring turns amber and shows minutes left; tap the YouTube pill, it opens.
14. After 2 min YouTube is blocked again; screen says "Emergency access has ended." and button says "No emergency access left".
15. End challenge early → "End this challenge?" with remaining time and ₹100 text. "Keep my commitment" goes back, nothing changes.
16. End challenge early → "End challenge — ₹100" → Payment screen shows "Payments are not connected yet … Nothing has been charged." No pay button. Challenge still running.

## D. Interruptions (challenge must stay active, nothing payable)
17. Force-close Commit from recents, reopen: same time remaining.
18. Restart the phone: challenge still running, YouTube still blocked.
19. Switch Accessibility off for Commit: amber "Your protection has been interrupted." card with "Restore protection". Switch it back on.
20. Airplane mode on: everything still works.

## E. Finish
21. Let the timer end: "Challenge complete 🎉", "You kept your commitment.", "5 minutes completed.", Amount payable ₹0.
    (If you did step 19, it instead says "Challenge period ended" – that is expected.)
22. "Start another challenge" opens Step 1. Go back; the finished challenge is under the History icon (top left of Home).
23. History: card shows result, duration, date, "Commitment Amount ₹100 · ₹0 payable". Tap it for details.

## F. Look and feel
24. No cut-off text, no overlapping buttons, on every screen above.
25. Increase phone font size (Settings → Display) one step: screens still readable and scrollable.

Report the step number and a screenshot for anything that looks wrong.
