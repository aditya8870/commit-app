# Commit 2.2.0 — protection audit

Status of this document: analysis from Android's documented behaviour and the
app's code, plus the device results reported for earlier versions. **Nothing in
2.2.0 has been run on a phone yet.** Rows marked "verify" depend on how the
phone maker implemented Android and must be checked with the test plan.

Classes: **A** preventable · **B** detectable · **C** recovers by itself ·
**D** not reliably preventable on normal Android.

## 1. Bypass methods

| # | Method | Class | What happens in 2.2.0 |
|---|--------|-------|------------------------|
| 1 | Force stop Commit | A with tamper protection (verify) · otherwise B, D | Android greys out "Force stop" for an active device-admin app, and tamper protection is now required to start a challenge. If it is switched off first, the force stop works: nothing of ours runs until Commit is opened again. On reopening, the stop is read from Android's exit records (Android 11+) and recorded on the challenge. |
| 2 | Disable Accessibility | B, C | Recorded at the moment it is switched off. The backup detector takes over within about 3 seconds. |
| 3 | Revoke Usage access / Display over other apps | B | With Accessibility on: no effect on blocking, shown as reduced protection. With Accessibility also off: blocking stops; the service notices, records it, and posts "Your protection has been interrupted". |
| 4 | Stop / kill the blocking service | C | The Accessibility service is re-bound by Android. It restarts the backup service if it finds it dead. The backup service is "sticky". |
| 5 | Restart phone / power off and on | C | Device-tested PASS on 1.3.0 and 2.0.0: blocked without opening Commit. All state comes from saved timestamps. |
| 6 | Open from Recent Apps | A | Device-tested PASS. |
| 7 | Open from a notification | A for opening the app · D for the notification itself | Tapping it opens the app, which is blocked. Reading the notification, or replying from it, is not blocked. |
| 8 | Open through a link | A for the app · D for the website | A link that opens the app is blocked. The same service in a web browser (instagram.com, youtube.com) is **not** blocked. |
| 9 | Widgets | A for opening · D for the widget | Tapping through to the app is blocked. Content shown inside a home-screen widget is not. |
| 10 | Other launch paths (search, share sheet, split screen, floating window) | A (verify) | All of these bring the app's window to the front, which is what is detected. Split screen and floating windows are untested. |
| 11 | "Lite" or alternative apps (Instagram Lite, YouTube in a browser, a second client) | D | Only the selected packages are blocked. |
| 12 | Cloned apps / second user / private space | D (verify) | A copy of the app in another profile may not be seen by the detectors. |
| 13 | Restrict battery / background activity | B, C | Android may stop the backup service. Accessibility normally survives. Device-tested PASS with the screen locked 20+ minutes. |
| 14 | Uninstall Commit | A with tamper protection | Device-tested PASS on 1.3.0: uninstall is refused. Switching tamper protection off is recorded and notified. |
| 15 | Clear app data | A (verify) | "Clear data" is replaced by "Manage space", which refuses while a challenge is live. Android also disables clearing data for active device-admin apps. |
| 16 | Switch tamper protection off in Settings | B | Android shows our warning first. If the user continues, it is recorded and notified. After that, rows 1 and 14 are open. |
| 17 | Change the clock | A within one boot · D after a reboot | Time runs on a clock that ignores manual changes. After a reboot with the clock set forward, the challenge can end early. |
| 18 | Safe mode | D | Android disables all downloaded apps, Commit included. Pre-installed apps (often YouTube) still run. |
| 19 | Another device | D | — |
| 20 | Disable / re-enable Android services | C | Covered by rows 2–4: detectors come back when re-enabled. |

## 2. What force stop really does

After a force stop Android puts the app in a "stopped" state: no services, no
alarms, no boot receiver, no push messages, and Accessibility is switched off.
**Only the user opening Commit (or tapping its notification) starts it again.**
No legitimate app can restart itself from this state.

So the design is:
- **Prevent it where Android allows:** tamper protection (device admin) is
  required to start a challenge; Android then disables Force stop, Uninstall
  and Clear data until the user switches tamper protection off.
- **Detect it afterwards:** on the next start Commit reads Android's own record
  of why its process ended and stores "force stopped at 14:02" on the challenge.
- **Recover:** the challenge, end time, emergency uses, amount and payment
  state are all still there; the backup detector resumes at once if its
  permissions are intact; the app asks for Accessibility to be restored.
- **Never punish automatically:** a force stop does not charge, does not end
  the challenge and does not start a payment.
- **Do not reward it either:** a challenge that reaches its end time with an
  interruption on record is shown as "Challenge period ended — protection was
  interrupted", not as kept, and is not counted in the completion rate.

## 3. States

Stored status (what the blocker acts on): ACTIVE, EMERGENCY, COMPLETED,
ENDED_EARLY, CANCELLED.

Shown state (adds the conditions on top of a running challenge):
ACTIVE, EMERGENCY, PROTECTION_INTERRUPTED, PAYMENT_PENDING, PAYMENT_VERIFIED,
ENDED_EARLY, COMPLETED, CANCELLED.

PROTECTION_INTERRUPTED and PAYMENT_PENDING are deliberately not stored
statuses: the blocker only blocks ACTIVE/EMERGENCY records, so storing them
would itself switch blocking off.

COMPLETED is reached only when the scheduled end time has passed. Inactivity
cannot bring that forward; it can only mean protection was off for part of the
time, which is what the interruption record captures.

## 4. Charging rule (unchanged)

No payment provider is connected. A charge can only ever follow: End Challenge
→ amount shown → Continue to Payment → Pay → provider processes → backend
verifies. Force stop, restart, lost permission, crash and being offline never
charge and never end a challenge.

## 5. What cannot be fixed inside the app

- A user who switches tamper protection off and then force-stops or uninstalls.
- Websites, widgets, notification content, Lite/alternative apps, cloned apps.
- Safe mode; a reboot with the clock moved forward; another device.

Closing the first one needs something outside the phone: either a deposit taken
at the start and returned on completion, or a server that notices the app has
gone silent. Both need a backend and are out of scope until payments are.
