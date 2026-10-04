# Commit 2.9.0 – Phase 6 remediation (Play-first release)

Date: 4 Oct 2026. App 2.9.0 (build 16). **Nothing was deployed, no SQL was applied, nothing was published, no payment was connected, no production project was created.**

## 0. Result in short

| Decision | Done |
|---|---|
| 1. Remove tamper protection | Device admin and the "Clear data" override are gone. Nothing was added in their place. Losing the phone's copy is recorded and never counts as a clean completion |
| 2. No real money | No amount is chosen, shown, stored or charged. A new challenge has amount 0. Ending early is not offered |
| 3. Accessibility | Service unchanged and narrow; `isAccessibilityTool` not set; disclosure + Agree / No thanks screen added |
| 4. Privacy wording | Rewritten to match what the app really sends |
| 5. Privacy policy | Full draft in `docs/PRIVACY_POLICY_DRAFT.md`; not published |
| 6. Package ID | Not changed. `com.commit.focus` recorded as the proposed final ID |
| 7. Production backend | Not created. `commit-dev` remains |
| 8. Retention | Not required by Play for an app without accounts, so nothing destructive was built. Design only (section 8) |
| 9. Build | SDK levels pinned (36/36/24), App Bundle builds, version 2.9.0+16, signing plan in section 9 |
| 10. Tests | All existing tests pass; 33 new Flutter, 15 new backend, 5 new Android tests |

**Needs your action before 2.9.0 works on `commit-dev`:** one new migration and the updated Edge Function (section 7). Until then 2.9.0 cannot start a challenge, because the live server still refuses amount 0. 2.8.0 keeps working before and after.

## 1. Tamper protection removed

| Before (2.8.0) | After (2.9.0) |
|---|---|
| Device-admin receiver; Android greyed out Uninstall and Force stop | Removed from manifest and code. Uninstall and Force stop work normally |
| Tamper protection required to start a challenge | A challenge needs only blocking (Accessibility, or Usage access + overlay) |
| `manageSpaceActivity` replaced "Clear data" and refused during a challenge | Removed. Android's normal "Clear data" works at any time |
| Warning text discouraged switching protection off | Removed |
| Setup: 5 switches | Setup: 4 switches, plus the line "You stay in control: you can switch any of these off in Android Settings at any time." |

A phone that had tamper protection on: when 2.9.0 installs over 2.8.0, the admin component no longer exists and Android drops it automatically.

Kept unchanged: app blocking (both detectors), interruption detection, notifications, restart after reboot, server sync, reinstall recovery, offline behaviour. Settings, the installer, the permission controller, the dialer and the launcher still can never be blocked.

### Loss of local continuity is not a clean completion

| Situation | On the phone | On the server (after the new migration) |
|---|---|---|
| Normal challenge, phone present at the end | "Challenge complete" | `completion: clean` |
| Blocking switched off / app force-stopped during the challenge | "Challenge period ended… not counted as fully kept" (as before) | `interrupted` |
| Data cleared or app reinstalled, Commit opened again before the end | Challenge restored and blocked again; marked "restored"; at the end "not counted as fully kept"; not counted in "Completed" | `interrupted` |
| App removed and never opened again before the end | – | `completed` with `completion: unconfirmed` (never `clean`) |
| Phone clock moved forward | Corrected on next contact (Phase 5) | `interrupted` |

The server marks a completion `clean` only if the phone itself confirmed it at or after the end time and no interruption, restore or clock jump was recorded.

## 2. No real-money behaviour

- The amount step is gone: the flow is 4 steps (apps → length → emergency access → review).
- New challenges are created with amount 0 on the phone and on the server.
- Removed from every screen: "Commitment Amount", "₹", "payable", "charged", "End challenge early", the payment preview screens, the "what costs money" guide. The guide now says: "Commit is free. This version never charges you anything."
- The consent tick now reads: "I understand that these apps stay blocked until the challenge ends and that the challenge cannot be shortened once it starts." (consent version `2026-10-06.1`).
- Ending early: the app refuses before contacting the server; the server would still answer `PAYMENTS_UNAVAILABLE`.
- A challenge created by an older version with an amount shows no money either.
- Manifest: the `upi://` query was removed. No payment SDK, no billing permission.

How it is built: one switch, `Features.payments` (`lib/core/features.dart`), default **off**. The earlier payment code is still in the project but unreachable; its tests run with the switch turned on inside the tests only. Nothing can charge even with the switch on, because no payment provider exists.

## 3. Accessibility disclosure (implemented)

Shown as its own screen the first time the user taps "Accessibility" (or "Turn on next step"), before Android settings open. "No thanks" goes back and opens nothing. "Agree" is saved and then Android settings open. Until "Agree" the app never opens the Accessibility settings.

> **Commit needs Accessibility access to block apps**
>
> Commit uses Android's Accessibility service for one purpose: to notice when an app you chose to block is opened, so it can cover it with the Commit screen straight away.
>
> **What Commit reads** – The name of the app that is open on your screen. Only while a challenge is running.
>
> **What Commit does not read** – Anything on your screen, your messages, your passwords, or what you type.
>
> **What is stored or sent** – The name of the open app is used on your phone at that moment. It is not saved and not sent anywhere. If Accessibility is switched off during a challenge, Commit records that this happened and sends that record to its server with your challenge.
>
> Commit is not an accessibility tool for people with disabilities. You can switch this access off at any time in Android Settings → Accessibility.
>
> [ Agree ]  [ No thanks ]

Text shown by Android in its own Accessibility settings (`accessibility_description`): "Commit uses Accessibility access only to notice when an app you chose to block is opened, so it can cover it with the Commit screen. It does not read screen content, messages, passwords or what you type. Which app is open is not saved or sent anywhere. Commit is not an accessibility tool for people with disabilities. You can switch this off here at any time."

Service configuration is unchanged: window-state events only, no access to window content, no gestures, no key events, `isAccessibilityTool` not set.

## 4. Privacy wording (implemented)

Settings → Privacy (subtitle "What Commit stores and sends") now states: no account; registration under a random ID with a hashed device identifier and versions; that the chosen apps, length, emergency settings, start/end time, emergency use and protection events are sent to the server and a copy kept on the phone; encrypted (HTTPS); no ads, no analytics, not sold; which app is open is not sent; no screen content.

Removed claims: "Everything stays on this phone", "Your challenges are stored on this phone", "uses the internet for one thing", "Nothing it detects leaves your phone". The word "anonymous" and any "no personal information" claim are not used.

Welcome screen adds: "No account required. No name, email or phone number."

## 5. Privacy policy

Complete draft: `docs/PRIVACY_POLICY_DRAFT.md`. Not published.

Exact URL needed before submission: one public HTTPS page, used in three places (web page, Play Console → App content → Privacy policy, and the build flag `--dart-define=commitPrivacyUrl=...` which makes the "Privacy policy" row appear in Settings). Proposed form: `https://[your-domain]/commit/privacy`. I cannot choose the address for you: tell me the domain or GitHub username.

Still to fill in: legal name, address, privacy email, effective date, Supabase region, retention decision, minimum age.

## 6. Play Data Safety matrix (updated for 2.9.0)

| Form question | Answer |
|---|---|
| Collects or shares user data | Yes (collects) |
| Encrypted in transit | Yes |
| Users can request deletion | No (until section 8 is built; then Yes) |
| Account creation | None |

| Data type | Collected | Shared | Required | Purpose |
|---|---|---|---|---|
| Device or other IDs (installation ID; hashed Android ID) | Yes | No | Required | App functionality; Fraud prevention, security and compliance |
| App activity → Installed apps (only the apps the user selects) | Yes | No | Required | App functionality |
| App activity → App interactions (challenge start/end, emergency use, completion) | Yes | No | Required | App functionality |
| App info and performance → Diagnostics (protection events, app and Android version) | Yes | No | Required | App functionality; Fraud prevention, security and compliance |
| Financial info | **No** (changed: no amount is collected in 2.9.0) | – | – | – |
| Everything else (location, personal info, messages, photos, contacts, health, web browsing, files, audio, calendar) | No | – | – | – |

Changes from the audit matrix: the commitment amount is no longer collected; the "tamper protection off" event no longer exists.

## 7. Backend changes (written, tested locally, NOT applied or deployed)

| File | Change |
|---|---|
| `backend/supabase/migrations/20261007090000_play_release.sql` | Amount rule becomes "0, or 100–10000"; new function `api_completion`; `api_challenge_json` adds `completion`; `api_complete_challenge` records once that the phone confirmed the end. No row changed or deleted, no table added, payments untouched |
| `backend/supabase/functions/api/index.ts` | Accepts `amountRupees: 0` (1–99 still refused) |
| `backend/tests/db/verify_phase6.sql` | Read-only check, 10 rows |

Order when you approve: migration → `verify_phase6.sql` (all `ok = true`) → Edge Function → `/v1/time` still answers → install 2.9.0. After this migration `verify_phase5.sql` reports 19 functions instead of 18; that is expected.

Rollback: reinstall 2.8.0; redeploy the Phase 5 `index.ts`; the migration can stay (it only loosens one rule and adds one function).

## 8. Retention and deletion – design only, nothing implemented

Required for compliance? Play: no – account-deletion rules apply to apps with accounts, and the Data Safety answer "No" is allowed. Law (India DPDP Act): probably yes, needs a lawyer. So nothing destructive was added.

Proposed design for your review:

1. Show the installation ID in Settings → Privacy so a user can quote it.
2. Deletion on request: email with the installation ID; a server function removes that installation's rows. The database currently forbids deleting challenge history, so this needs a deliberate, reviewed migration.
3. Automatic: an installation with no contact for 12 months and no active challenge is deleted by a scheduled job.
4. Never delete an active challenge or (in future) a row tied to a payment.

## 9. Build and release status

| Item | Status |
|---|---|
| compileSdk / targetSdk / minSdk | 36 / 36 / 24, now written in `android/app/build.gradle.kts` (verified in the built APK) |
| Version | 2.9.0 (build 16) |
| App Bundle | `flutter build appbundle --release` succeeds (49.8 MB, all ABIs). Signed with the debug key – for checking only, **not uploadable** |
| Release config | R8 and resource shrinking on, not debuggable, cleartext off, backups off |
| Application ID | `com.commit.app` (unchanged). Proposed final: `com.commit.focus` |
| Android lint | 0 errors, 23 warnings (style suggestions, deprecated-API notes, `HardwareIds` for the intended ANDROID_ID use) – same count as before |

Signing plan (not executed):

1. Decide the final application ID and apply it (one line) before the first upload.
2. On your own computer create an upload keystore with `keytool`; store it and its passwords outside the project, with an offline backup.
3. Copy `android/key.properties.example` to `android/key.properties` and fill it in (both are git-ignored).
4. In Play Console create the app and enrol in Play App Signing; Google holds the app signing key, you hold the upload key.
5. Build with `flutter build appbundle --release --dart-define=commitApiBase=<production API> --dart-define=commitPrivacyUrl=<policy URL>` and upload to the internal test track first.

## 10. Tests

| Suite | Before (2.8.0) | After (2.9.0) |
|---|---|---|
| Flutter tests | 226 pass, 3 skipped | **259 pass**, 3 skipped |
| Flutter end-to-end (local handler + DB) | 3 pass | 3 pass |
| Static analysis | no issues | no issues |
| Backend Phase 1 / 2 / 3 / 5 | 10 / 131 / 48 / 38 | 10 / 131 / 48 / 38 |
| Backend Phase 6 | – | **15 pass** |
| Edge Function type check | clean | clean |
| Android unit tests | 3 pass | **8 pass** |
| Android lint | 0 errors, 23 warnings | 0 errors, 23 warnings |

Existing tests that had to change, and why:

| Test | Change | Reason |
|---|---|---|
| "a challenge cannot start without tamper protection" (widget) | Now checks that no tamper step exists and the flow starts | Decision 1 |
| "no start without tamper protection" | Now "a challenge can start with blocking alone" | Decision 1 |
| "tamper protection being switched off is recorded" | Now checks an old record is read harmlessly | Decision 1 |
| Engine: amount 0 refused | 0 is accepted as "no financial commitment"; 1–99 still refused | Decision 2 |
| Database: "amount 0 is refused" | Replaced by "amount 50 is refused" | Decision 2 |
| Payment/checkout suites | Unchanged, but run with the payments switch turned on inside the test | The code is dormant in the release |

New tests cover: tamper protection removed (manifest, native code, Dart, setup screen); uninstall not blocked; "Clear data" not replaced; restore after cleared data is not a clean completion; disclosure shown before settings, "No thanks", "Agree", consent saved; no money on any screen of the flow, blocked screen, emergency, guide, history, settings, old challenges; end-early refused without a server call; amount 0 sent; privacy wording; blocking state, offline queue and server sync unchanged; server completion quality (clean / interrupted / unconfirmed).

Not tested: anything on a physical phone. A device test is needed after deployment (section 12).

## 11. Changed files

New:
- `lib/core/features.dart`
- `test/play_release_test.dart`
- `android/app/src/test/kotlin/com/commit/app/PlayPolicyTest.kt`
- `backend/supabase/migrations/20261007090000_play_release.sql`
- `backend/tests/play_release.test.mjs`
- `backend/tests/db/verify_phase6.sql`
- `docs/PHASE6_REMEDIATION.md`, `docs/PRIVACY_POLICY_DRAFT.md` (and `docs/PHASE6_PLAY_AUDIT.md` from the audit)

Deleted:
- `android/.../CommitAdminReceiver.kt`
- `android/.../ManageSpaceActivity.kt`
- `android/app/src/main/res/xml/device_admin.xml`

Changed (app):
- `android/app/src/main/AndroidManifest.xml` – admin receiver, manage-space activity, `upi` query and a stray attribute removed
- `android/app/src/main/res/values/strings.xml` – Accessibility description
- `android/.../MainActivity.kt` – three admin methods removed, `openUrl` (https only) added
- `android/.../IntegrityLog.kt` – unused tamper/payment helpers removed
- `android/app/build.gradle.kts` – SDK levels pinned, ID note
- `pubspec.yaml` – 2.9.0+16
- `lib/core/commitment_engine.dart` – amount 0, new consent text/version, clean-completion rule, new error
- `lib/core/commitment.dart` – "restored" marker
- `lib/platform/platform_bridge.dart` – admin methods removed, `openUrl` added
- `lib/data/commit_controller.dart` – no tamper requirement, Accessibility consent, restore marker, end-early guard
- `lib/data/http_backend.dart` – accepts amount 0
- `lib/ui/widgets.dart`, `lib/ui/format.dart`
- `lib/ui/screens/create_flow.dart`, `commitment_screens.dart`, `welcome_home.dart`, `emergency.dart`, `history_settings.dart`

Changed (backend): `supabase/functions/api/index.ts`, `tests/run_all.sh`, `tests/db/10_tests.sql`.

Changed (tests): `test/fakes.dart`, `widget_test.dart`, `integrity_test.dart`, `engine_test.dart`, `challenge_sync_test.dart`, `backend_test.dart`, `controller_test.dart`, `payment_test.dart`, `stage1_test.dart`, `hardening_test.dart`.

## 12. Device test after deployment (short)

| # | Step | Expected |
|---|---|---|
| 1 | Install 2.9.0 over 2.8.0 | Installs; Settings → Apps → Commit shows Uninstall and Force stop enabled |
| 2 | Open setup | 4 switches, no tamper protection |
| 3 | On a fresh install tap Accessibility | Disclosure with Agree / No thanks; "No thanks" opens nothing; "Agree" opens Android settings |
| 4 | Start a challenge | 4 steps, no ₹ anywhere; Supabase `challenges.amount_rupees` = 0 |
| 5 | Open a blocked app | Blocked as before; no "End challenge early" |
| 6 | Settings → Apps → Commit → Storage | Normal "Clear data" button. Clear it, open Commit online | Challenge restored and blocked; at the end "not counted as fully kept" |
| 7 | Let a clean challenge finish, then in SQL: `select public.api_completion(c) from public.challenges c order by created_at desc limit 2;` | `clean` for the undisturbed one, `interrupted` for the restored one |
| 8 | Settings → Privacy | New text; no claim that everything stays on the phone |

## 13. Release-readiness status

| Area | Status |
|---|---|
| Target API 36 | Ready |
| Accessibility policy (disclosure, consent, not a tool, no uninstall prevention) | Ready in the app; Play Console declaration + video still to do |
| No payments / no money wording | Ready |
| Privacy wording in app | Ready |
| Privacy policy | Draft ready; not published |
| Data Safety answers | Prepared |
| App Bundle | Builds; not signed for upload |
| Backend for 2.9.0 | Written and tested; not deployed |
| Device test of 2.9.0 | Not done |

## 14. Remaining issues

### P0 – before Play submission

| # | Item | Who |
|---|---|---|
| 1 | Deploy the Phase 6 migration + function to `commit-dev`, device-test 2.9.0 | You (steps in section 7), then me for any fix |
| 2 | Publish the privacy policy; give me the URL | You |
| 3 | Apply the final application ID (`com.commit.focus`) | Your go-ahead, one line |
| 4 | Upload key, Play App Signing, signed App Bundle | You, guided |
| 5 | Production API address for release builds (needs the production project) | Decision 7 postponed this |
| 6 | Put the source in git with a private remote backup | Your go-ahead |
| 7 | Play Console: Accessibility declaration + video, foreground-service declaration + video, Data Safety, content rating, target audience, store listing, reviewer notes | You, I prepare the texts |
| 8 | Closed test (12 testers, 14 days) if your Play account is a new personal account | You |

### P1 – before public release

1. Production Supabase project (paid plan), secrets, migrations, monitoring, backups.
2. Retention and deletion (section 8) + legal review (DPDP).
3. Consent-style explanation before Usage access and overlay settings.
4. Device testing on Android 16 and other manufacturers; TalkBack and large text.
5. Support email, FAQ, first-launch-offline message.
6. Show server completion quality in the app's history (the app currently uses its own local record).
7. Remove the dormant payment code entirely if the payment model is dropped; otherwise re-evaluate against Play policy first.

### P2 – after launch

Certificate pinning; Dart obfuscation; nightly server sweep for overdue challenges; tablet layouts; languages; the 23 lint style warnings.
