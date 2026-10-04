# Commit 2.8.0 – Phase 6: Google Play compliance and production-readiness audit

Audit date: 4 Oct 2026. Audited: app 2.8.0 (build 15), backend as deployed on `commit-dev`.
**Nothing was changed, deployed, applied or published.** This file is the only new file.

How to read this: "Verified" means I read it in the project or the built APK. "Policy" means I read it on Google's official policy pages on the audit date (links at the end). I am not a lawyer; items marked **CONFIRM** need a decision from Google Play support or a lawyer before you rely on them.

## 0. Summary

| | Count | Most important |
|---|---|---|
| P0 – must fix before Play submission | 9 | Tamper protection is mandatory; in-app privacy text is now wrong; no consent screen for Accessibility; debug signing; no privacy policy; payment model unconfirmed |
| P1 – should fix before public release | 9 | Production Supabase project; data deletion and retention; monitoring; offline-clear escape route |
| P2 – can fix after launch | 6 | Certificate pinning, tablets, localisation |

Already good: target API 36, no `QUERY_ALL_PACKAGES`, Accessibility service cannot read screen content, HTTPS only, no secrets in the APK, backups off, no third-party SDKs, no analytics, no ads.

## 1. AccessibilityService (deliverable D)

### 1.1 What the code does (verified)

| Item | Finding |
|---|---|
| Config | `typeWindowStateChanged` only, `canRetrieveWindowContent="false"`, no gestures, no key filtering, `isAccessibilityTool` not set |
| Data read | Only the package name of the app whose window came to the front |
| When | While a challenge is running. With no challenge the event filter is narrowed to Commit's own package |
| What it does with it | If the package is one the user locked: draws an opaque overlay (`TYPE_ACCESSIBILITY_OVERLAY`), sends a media "pause" key, opens Commit's blocked screen |
| Global actions | One: `GLOBAL_ACTION_HOME`, only when the user taps the button on the blocked screen |
| Stored / sent | The foreground package name is never stored and never sent. Only "Accessibility was switched off during a challenge" is recorded and uploaded as an event |
| Settings changes | None. The service changes no system setting |
| Blocks Settings? | No. Settings, dialer, launcher, installer, permission controller and keyboards can never be selected for blocking (`AppListProvider`) |

### 1.2 Should Commit declare `isAccessibilityTool`?

**No.** Policy: only services "designed to help people with disabilities" may set it; automation, monitoring and similar apps are named as not qualifying. Commit is a self-control tool. Leave the flag unset. Consequence: prominent disclosure + consent in the app, and the Accessibility declaration in Play Console, are both mandatory.

### 1.3 Gaps against policy

| # | Requirement (policy) | Current state | Gap |
|---|---|---|---|
| A1 | Prominent disclosure shown in normal use, right before the permission, separate from other notices | The setup screen shows a card "What Commit can see" on the same screen as 5 switches | Not a separate disclosure; no explicit consent |
| A2 | Affirmative consent with two options (agree / decline), wording like "Agree" | Tapping the row opens Android settings directly | **No consent step** |
| A3 | Disclosure must describe data accessed and how it is used/shared | Text says "Nothing it detects leaves your phone" | Accurate for the foreground-app signal, but the list of locked apps and the "Accessibility switched off" event are uploaded since 2.8.0. Wording must not over-promise |
| A4 | "The Accessibility API cannot be used to … prevent the ability for users to disable or uninstall any app" | The Accessibility service itself does not do this. But the same app has mandatory device-admin "tamper protection" and replaces "Clear data" during a challenge | **Highest review risk in the app** – see section 11, R1 |
| A5 | No autonomous actions | Behaviour is a fixed rule the user set | OK |
| A6 | Prefer narrower APIs when they can do the job | Usage Access + overlay already exist as a backup detector | Reviewer may ask why Accessibility is needed at all. Answer: Usage Access is polled (delay of about a second, app content visible); Accessibility is immediate. Keep this in the declaration |
| A7 | Play Console Accessibility declaration + video of the disclosure and consent | Not done | Needed at submission |

### 1.4 Proposed disclosure wording (NOT implemented)

Shown as its own full screen the first time the user taps "Accessibility", before Android settings open.

> **Commit needs Accessibility access to block apps**
>
> Commit uses Android's Accessibility service for one purpose: to notice when an app you chose to lock is opened, so it can cover it with the Commit screen straight away.
>
> **What Commit reads:** the name of the app that is currently open. Only while a challenge is running.
>
> **What Commit does not read:** anything on your screen, messages, passwords, or what you type.
>
> **What is stored or sent:** the name of the open app is used on your phone at that moment and is not saved or sent anywhere. If Accessibility is switched off during a challenge, Commit records that this happened and sends that record to its server with your challenge.
>
> Commit is not an accessibility tool for people with disabilities. You can switch this off at any time in Android Settings → Accessibility.
>
> [ **Agree** ]  [ **No thanks** ]

"No thanks" returns to setup without opening Settings. The Android settings description string (`accessibility_description`) must be changed to match (it currently says nothing is sent off the device).

### 1.5 Play Console declaration (answers to prepare)

| Question | Answer |
|---|---|
| Is it an accessibility tool? | No |
| Purpose | App functionality: block user-selected apps during a user-set period |
| Personal/sensitive data collected through the API | None is collected through the API (foreground package name is processed on device only) |
| Video | Screen recording: setup → disclosure → Agree → Android settings → start a challenge → open locked app → blocked |

## 2. Installed-app visibility (deliverable E)

| Item | Finding (verified) |
|---|---|
| `QUERY_ALL_PACKAGES` | **Not used.** Not in the source or merged manifest |
| `getInstalledPackages` / `getInstalledApplications` | Not used |
| Mechanism | `<queries>` with 5 intents: launcher apps, home apps, dialer, `upi://` handlers, `PROCESS_TEXT` (Flutter engine) |
| What the app sees | Apps with a launcher icon (name, package, icon) – needed for the "choose apps" list |
| Narrower option? | The launcher-intent query is already the narrow, recommended mechanism. No change needed |
| Play declaration | None for package visibility, because the broad permission is not requested |
| Still required | Policy treats the installed-app inventory as personal and sensitive data. The full list stays on the phone; **only the apps the user selects** (package name + app name) are sent to the server. This must be in the Data Safety form and privacy policy |
| Unused query | `upi://` exists only for the future payment checkout. Harmless, but remove it if payments are not built (P2) |

## 3. Permission inventory (deliverable B)

From the merged release manifest (verified). Nothing else is requested: no storage, location, camera, contacts, exact alarms, phone, SMS.

| Permission / capability | Why it exists | Required? | Play status | Disclosure | Remove? |
|---|---|---|---|---|---|
| `INTERNET` | Register installation; create/sync challenges | Yes | Normal | Privacy policy + Data Safety | No |
| Accessibility service (`BIND_ACCESSIBILITY_SERVICE`) | Primary detector: blocks instantly | Yes | Restricted: declaration + disclosure + consent | **Prominent disclosure + consent (missing)** | No |
| `PACKAGE_USAGE_STATS` (Usage access) | Backup detector if Accessibility is off | Optional in app | Special access, user grants in Settings. No Play form found; expect reviewer scrutiny | In-app explanation before sending to Settings (add consent text) | Keep; consider dropping if reviewers object to two detection methods |
| `SYSTEM_ALERT_WINDOW` | Backup detector's lock overlay | Optional in app | Special access, user grants in Settings | In-app explanation | Tied to Usage access: keep or drop together |
| `FOREGROUND_SERVICE` | Runs the backup detector and the "challenge active" notification | Yes while backup exists | Normal | – | No |
| `FOREGROUND_SERVICE_SPECIAL_USE` | Service type for the above | Yes (no standard type fits) | **Play Console foreground-service declaration + video required; "special use" gets extra review** | Declaration | No |
| `POST_NOTIFICATIONS` | "Challenge active" and "protection interrupted" notifications | Optional (blocking works without) | Runtime permission | Standard system prompt | No |
| `RECEIVE_BOOT_COMPLETED` | Restart blocking after reboot | Yes | Normal | – | No |
| Device admin receiver (`BIND_DEVICE_ADMIN`), no policies | "Tamper protection": uninstall and force-stop are greyed out until the user switches it off | **Currently mandatory to start a challenge** | Allowed API, but see R1 | System device-admin prompt (exists) | **Make optional (P0)** |
| Battery optimisation settings screen | Opens the settings list only; `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is **not** requested | Optional | OK (no restricted permission) | – | No |
| `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | Added automatically by AndroidX | – | Internal | – | No |
| `android:manageSpaceActivity` | Replaces "Clear data" with Commit's own dialog; refuses while a challenge is live | No | Not a permission, but restricts a user control | – | **Review with R1** |

Not present and not needed: exact alarms, full-screen intent, storage, `QUERY_ALL_PACKAGES`.

## 4. Data inventory and Data Safety matrix (deliverable C)

### 4.1 Inventory (verified)

| Data | On phone | Sent to server | Stored on Supabase | Notes |
|---|---|---|---|---|
| Installation ID (server-issued UUID) | Yes, encrypted (AES-256-GCM, Android Keystore) | Every signed request | `installations.id` | Pseudonymous identifier |
| Credential (256-bit random) | Yes, encrypted | Every signed request (header) | SHA-256 hash only | |
| Android ID (`ANDROID_ID`) | Read in native code only | **Never raw.** SHA-256("commit-recovery-v1:"+ID) is sent | HMAC-SHA-256 of that value with a server-only key | Device identifier → must be declared |
| App version, Android version | – | At registration/recovery | `installations` | |
| Timestamps (created, last seen, last recovered), recovery count | – | – | `installations` | |
| Selected apps: package name + app name | Yes (state file) | When a challenge is created | `challenge_apps` | "Installed apps" data type |
| Full installed-app list and icons | In memory for the picker | No | No | |
| Challenge: duration, amount (₹), emergency settings, consent version, start/end, status | Yes | Yes | `challenges` | Amount is a chosen number; no payment happens |
| Emergency uses (time, minutes) | Yes | Yes | `emergency_uses` | |
| Protection events (force stop, accessibility off, tamper protection off, protection lost/restored, clock jump, restored) with device time | Yes | Yes | `challenge_events` | App interactions / diagnostics |
| Foreground app while a challenge runs | In memory only | No | No | |
| IP address | – | Inherent in any request | Keyed hash in `rate_limits`, deleted after 1 day. Supabase's own platform logs also see IPs | Declare under service-provider processing in the privacy policy |
| Name, email, phone, account, location, contacts, ads ID, analytics | Not collected | – | – | |
| Payment data | None exists | – | `payments` table is empty | |

Encryption: in transit HTTPS only (cleartext disabled). At rest: Supabase encrypts its database storage (platform feature – state it as the provider's, not ours). On the phone: credential encrypted with Keystore; challenge state is in app-private SharedPreferences (not separately encrypted). Backups and device transfer are disabled.

Retention (verified): **there is none.** Installations, challenges, apps, events and emergency uses are kept indefinitely; database triggers forbid deleting them. There is no way for a user to request deletion. See P1-2.

Sharing: no data goes to any third party other than Supabase acting as hosting provider (a "service provider", which the form does not count as sharing).

### 4.2 Data Safety form – proposed answers

| Form question | Answer |
|---|---|
| Does the app collect or share user data? | Yes (collects) |
| Is all data encrypted in transit? | Yes |
| Can users request deletion? | Currently **No** – becomes Yes only after P1-2 |
| Account creation | The app has no accounts |

| Data type (Play category) | Collected | Shared | Processed ephemerally | Required or optional | Purpose |
|---|---|---|---|---|---|
| Device or other IDs (installation ID; hashed Android ID) | Yes | No | No | Required | App functionality; Fraud prevention, security and compliance |
| App activity → Installed apps (only the apps the user selects) | Yes | No | No | Required | App functionality |
| App activity → App interactions (challenge start/end, emergency use) | Yes | No | No | Required | App functionality |
| App info and performance → Diagnostics (protection events, app/OS version) | Yes | No | No | Required | App functionality; Fraud prevention, security and compliance |
| App activity → Other user-generated content | No | – | – | – | – |
| Financial info | **No today.** Becomes Yes ("Purchase history" / "User payment info") the day a payment exists | – | – | – | – |
| Location, Personal info, Messages, Photos, Contacts, Health, Web browsing, Files, Calendar, Audio | No | – | – | – | – |

**CONFIRM:** whether the commitment amount (a number the user picks, no money moved) should be declared under Financial info → "Other financial info". The conservative choice is to declare it as collected for app functionality.

## 5. Privacy policy – required content (not published)

A privacy policy is mandatory for every app on Play: a public URL in Play Console **and** a link inside the app. It must contain:

1. Who you are: developer/legal name and a contact email for privacy questions.
2. What is collected, matching section 4.1 exactly: installation ID; a hashed device identifier used only to recognise the same phone after reinstall; app and Android version; the apps you select to lock (name and package); challenge details including the commitment amount; emergency uses; protection events; timestamps; IP address in server logs.
3. What is not collected: no name, email, phone number or account; no screen content, messages, passwords or typing; no location; no advertising ID; no analytics or ads. (Say "no account required", never "no personal information".)
4. How Accessibility, Usage access and "display over other apps" are used, in the same words as the in-app disclosure.
5. Why: to run and restore challenges, keep challenge time honest, prevent abuse.
6. Where it is stored and who processes it: Supabase (hosting provider) and the region of the production project.
7. Sharing: not sold, not shared for advertising or analytics; only the hosting provider and legal requests.
8. Security: HTTPS, encrypted credential on the device, hashes instead of raw identifiers, server-only keys.
9. Retention and deletion: a real retention period and a real way to ask for deletion (needs P1-2 first; the policy must not promise what the system cannot do).
10. Children: not directed at children (and the app involves money) – state the minimum age.
11. Payments section: add only when payments exist.
12. Changes to the policy and effective date.

**CONFIRM (lawyer):** India's DPDP Act obligations (notice, consent, grievance contact, deletion), since users and developer are in India.

## 6. Target API and build (deliverable F) – verified from project and built APK

| Item | Value | Source |
|---|---|---|
| compileSdk | 36 | Flutter default (`flutter.compileSdkVersion`); APK reports 36 |
| targetSdk | **36** | Flutter default; APK reports 36 |
| minSdk | 24 (Android 7.0) | Flutter default; APK reports 24 |
| Android Gradle Plugin | 9.1.0 | `settings.gradle.kts` |
| Gradle | 9.3.1 | wrapper |
| Kotlin | 2.4.0 | `settings.gradle.kts` |
| Java / Kotlin JVM target | 17 / 17 | `app/build.gradle.kts` |
| NDK | 28.2.13676358 | Flutter default |
| Flutter / Dart | 3.47.6 stable / 3.13.5 | `flutter --version` |
| Release build | R8 minify on, resource shrinking on (Flutter defaults), not debuggable, **signed with the Android debug key** | Flutter plugin; `apksigner` |
| Native libraries | arm64-v8a only in this APK; both libraries are 16 KB page-size compatible | ELF check |

**Result: the project already targets API 36. No target-API change is required** for the 31 Aug 2026 rule (new apps and updates must target Android 16 / API 36).

Risks to keep in mind:

- The SDK numbers are inherited from the installed Flutter version, not written in the project. A different Flutter version on another machine changes them silently. Pin them explicitly (P1).
- Android 16 behaviour for API 36 that touches Commit: edge-to-edge is mandatory (Flutter handles it; verify the two native dialogs/overlay); predictive back is on by default (Flutter 3.47 supports it; verify back on the blocked screen); on tablets/foldables orientation locks are ignored (layouts are not tablet-tested). None was seen failing, none was tested on an Android 16 device here.
- Device admin without policies still works on Android 16 but the API family is long deprecated; see R1.

## 7. Security (deliverable G)

| Area | Finding | Status |
|---|---|---|
| Secrets in app | None. No Supabase anon or service key, no recovery key in Dart/Kotlin | OK |
| API URL | `commit-dev` address is the **compiled-in default** (`--dart-define=commitApiBase` overrides) | **P0: a production build must not point at dev** |
| Service-role key | Exists only inside Supabase's Edge Function environment | OK |
| Recovery secret | Supabase secret, versioned, never logged | OK |
| Credentials on device | AES-256-GCM, Keystore-backed; not in SharedPreferences | OK |
| Logs | No `Log.*`, `print` or `debugPrint` in app code. Server logs only method + path | OK |
| Debug vs release | Release is not debuggable, minified | OK |
| Signing | Debug key | **P0** |
| Backup | `allowBackup=false`, extraction rules exclude everything | OK |
| Exported components | `MainActivity` (launcher), `ManageSpaceActivity` (must be exported for Settings; shows a dialog only), `CommitAdminReceiver` (protected by `BIND_DEVICE_ADMIN`). Accessibility service, blocker service, boot receiver not exported | OK |
| Deep links | None | OK |
| Cleartext | Disabled; the API client refuses non-HTTPS | OK |
| Manifest slip | A stray `android:usesCleartextTraffic="false"` sits on the Accessibility `<service>` tag. Ignored by Android, harmless, should be deleted | P2 |
| WebView | None | OK |
| Certificates | System trust store; no pinning | P2 |
| Third-party SDKs | None at runtime | OK |
| Source control | **The project is not a git repository.** No history, no backup of the source | **P0** |
| Ignore rules | `key.properties`, `*.jks`, `.env.*` ignored (ready for git) | OK |
| Generated files | `build/`, `.dart_tool/` ignored | OK |
| Tamper resistance | A rooted phone or modified APK can bypass blocking and reporting. No Play Integrity check | P1 before payments |
| Abuse | Rate limits per address, per device, per installation and global | OK |

## 8. Production backend

| Item | Finding | Action |
|---|---|---|
| Environment | Only `commit-dev` exists and holds test data | P1: separate production project, own secrets, own recovery key |
| Migrations | 4 ordered SQL files, applied by hand in the dashboard | P1: apply the same 4 files to production; keep a written log of what was applied where |
| RLS | On for all 8 tables, 0 policies, app roles revoked; all access through 18 server functions callable by `service_role` only | OK |
| Edge Function | Verify JWT off by design (own credential scheme); validates every field; 32 KB body cap | OK |
| CORS | No CORS headers (mobile app only) | OK |
| Rate limits | 7 buckets, stored hashed, cleaned after 1 day | OK; revisit numbers with real traffic |
| Logging | Path-only; no bodies | OK |
| Retention | None defined | P1-2 |
| Failure behaviour | Server down → running challenges keep blocking; new challenges cannot start; queue retries | OK |
| Monitoring | None. No alert if the function fails or the database fills | P1: uptime check on `/v1/time`, Supabase log alerts, weekly row-count check |
| Backups | Depends on the Supabase plan (free plan has no point-in-time recovery) | P1: confirm the plan before real users |
| Free-plan pausing | Free Supabase projects pause after inactivity – unacceptable for production | P1: paid plan |
| Completion | Lazy (on next request). A challenge of a phone that never returns stays "active" in the table until then | P2: nightly sweep |

## 9. Payment readiness – questions only (deliverable H)

Model: user picks an amount; finishing costs ₹0; ending early may make the amount payable. **Nothing below says the model is allowed or prohibited. No official policy text I read addresses this model directly.**

| # | Question to confirm | Why it matters (policy read) |
|---|---|---|
| Q1 | Is the early-end charge a purchase of a **digital good or service inside the app** (unlocking app functionality)? | If yes, the Payments policy requires Google Play's billing system (or an enrolled alternative-billing programme) and forbids steering to other payment methods. "Unlock my apps now" looks like app functionality |
| Q2 | If Play Billing is required, can a **variable amount ₹100–₹10,000 chosen by the user** be modelled? | Play products have set price points; needs a product per amount tier. Google's service fee applies |
| Q3 | Could it instead fall under a category where Play Billing **must not** be used (physical goods, peer-to-peer, donations)? | Policy lists these exceptions. A penalty kept by the developer is none of them. If the money went to a registered charity it might be a donation – a different product, needs confirmation |
| Q4 | Does putting money "at stake" bring the app under **Real-Money Gambling, Games and Contests**? | Policy text targets staking money "to obtain a prize of real world monetary value". Commit pays nothing out, so the text does not obviously apply – but the page does not address stake-without-prize. Ask Google |
| Q5 | Is charging a penalty consistent with **Subscriptions / deceptive pricing** rules: clear terms before commitment, no surprise charges? | Payments policy requires clear and accurate terms and pricing. The consent screen must state the amount, when it is charged, and that there is no refund |
| Q6 | Is UPI/Razorpay allowed for this in India under **user-choice/alternative billing**? | Policy allows alternatives only for enrolled developers in eligible countries, with extra terms and reporting |
| Q7 | Legal: is a self-imposed penalty an enforceable, lawful charge in India (Contract Act, consumer protection, RBI rules on stored value / recurring mandates, GST)? | Outside Play policy. Lawyer |
| Q8 | Authorisation timing: is the user charged at the moment of ending early (a purchase), or is a mandate/hold taken at the start? | A hold or mandate changes which rules apply (pre-authorisation, e-mandate) |
| Q9 | Refunds and disputes: who handles "I was charged by mistake"? | Play requires a support contact and refund handling for Play Billing purchases |
| Q10 | Minimum age | Money + behavioural product: likely 18+; affects content rating and Families policy |

Technical note for whichever answer comes back: the current flow already matches "pay at the moment of ending early, server verifies, never trust the client", and exempts UPI apps and the Play Store from blocking during checkout.

## 10. Release engineering

| Item | Finding | Action |
|---|---|---|
| Application ID | `com.commit.app` (template TODO comment still present). **Permanent once published.** Availability on Play not checked | P0: choose the final ID before first upload (your own domain style, e.g. `in.yourname.commit`) |
| Namespace | `com.commit.app` | Changing the ID does not require changing Kotlin packages |
| Versioning | `2.8.0+15` from `pubspec.yaml`; build number increases each release | OK |
| Signing | Debug key. `key.properties` support exists | P0: create upload key, enrol in Play App Signing, back up the keystore offline |
| First release-signed build | Will not install over debug-signed test builds | Uninstall test builds first (documented in `RELEASE_SIGNING.md`) |
| Bundle | Only APKs have been built | P0: `flutter build appbundle` – Play requires an AAB for new apps |
| R8 | On by default; no custom keep rules needed today (no reflection, no plugins) | Verify the AAB on a device |
| Obfuscation of Dart | Not enabled | P2: `--obfuscate --split-debug-info` |
| Crash handling | No crash reporting; Dart errors are not captured | P1: rely on Play Console Android vitals first; add a reporter later only with a privacy-policy update |
| Network security | Cleartext off; system CAs | OK |
| Backup | Off | OK |
| ABIs | Test APK is arm64 only; an AAB includes all ABIs | OK with AAB |
| Device range | minSdk 24. Tested on one phone | P1: test on Android 16 and on a Xiaomi/Samsung/Oppo device (aggressive battery managers) |
| Play testing rule | Personal developer accounts created after 13 Nov 2023 need a closed test with **12 testers for 14 continuous days** before production | Plan 3+ weeks |
| Store listing | Not prepared: description, screenshots, content rating, target audience, ads declaration (No), data safety, privacy policy URL, app access instructions for reviewers | P0 at submission |
| Reviewer access | Reviewers must be able to reach every feature: provide step-by-step notes and a short video | P0 |

## 11. Store review risks

| # | Policy area | Current implementation | Potential issue | Severity | Proposed fix |
|---|---|---|---|---|---|
| R1 | Accessibility API ("cannot … prevent the ability for users to disable or uninstall any app"); Mobile Unwanted Software ("uninstall … simple, clear and straightforward") | Device-admin "tamper protection" is **required** to start a challenge; "Clear data" is replaced during a challenge; the admin-disable warning discourages switching off | An app that uses Accessibility and also makes itself hard to remove matches a pattern reviewers reject, even though the block is done with device admin, not Accessibility, and the user can always switch it off in Settings | **High** | Make tamper protection clearly optional and off by default; describe it honestly ("adds a step before uninstalling"); remove the persuasive sentence from the disable warning; consider removing `manageSpaceActivity`. Record uninstall/clear as "challenge not completed" on the server instead of preventing it. **CONFIRM with Play support** whether optional device-admin friction is acceptable |
| R2 | Accessibility API – disclosure and consent | No dedicated consent screen | Standard rejection reason "missing prominent disclosure" | **High** | Section 1.4 |
| R3 | User Data – accuracy | Settings → Privacy says challenges are stored on the phone and internet is used for one thing; Accessibility description says nothing is sent | Since 2.8.0 challenges and selected apps go to the server: the statements are now inaccurate | **High** | Rewrite both texts to match section 4.1 |
| R4 | Payments | Model undecided; app text mentions a Commitment Amount and "you pay ₹0" | Reviewer may ask how money is charged; text implying off-Play payment can be read as steering | **High** until decided | Decide Q1–Q6 before submission; if payments are not in v1, remove the amount or label it clearly as not charged |
| R5 | Foreground service `specialUse` | Declared with a subtype description | Needs Console declaration + video; special use is reviewed case by case | Medium | Prepare description: "keeps user-selected apps blocked for a user-set period; user sees an ongoing notification; ends automatically at the end time" |
| R6 | Minimum-scope APIs | Accessibility + Usage access + overlay | "Why three sensitive capabilities?" | Medium | Keep backup optional; explain in the declaration; be ready to drop the backup |
| R7 | Device and Network Abuse – interfering with other apps | Covers other apps and pauses their media, only apps the user selected | Blocking apps is an established category; risk is low if it is user-initiated and clearly disclosed | Low–Medium | State "user-selected apps only" in listing and declaration |
| R8 | Data Safety accuracy | Not filled | Mismatch between form and behaviour is a common rejection | Medium | Use section 4.2 |
| R9 | Target audience / minors | Not set | Money-related self-control app | Medium | Target 18+ |
| R10 | Misleading claims | "No account required" (fine) | Any absolute "no personal information" claim would be false (device ID hash, installed apps) | Low | Keep current positioning |

## 12. Customer experience (audit only)

| Area | Finding | Priority |
|---|---|---|
| First run | Welcome → "Get started" → setup with 5 switches | A new user meets 5 system-settings trips before any value. Fine functionally; heavy. Not redesigning now |
| Permission explanation | One-line reasons per switch; no per-permission consent screen | P0 for Accessibility (policy), P1 for Usage access and overlay |
| Tamper protection wording | "Stops Commit being removed during a challenge"; labelled as required | P0 with R1 |
| Privacy text | Outdated (R3) | P0 |
| Privacy policy link | None in the app | P0 |
| Starting offline | Clear message: "The server could not be reached. Nothing was started." | OK |
| First launch offline | Registration retries silently; user only finds out when starting a challenge | P1: say "connect to the internet to start your first challenge" |
| Running offline | Unchanged behaviour, no error noise | OK |
| Ending early | Says payment is not available; challenge stays | Must be consistent with R4 |
| Recovery after reinstall | Automatic, with a notice "Your running challenge was restored" | OK |
| Clock change | Notice explains the challenge is still running | OK |
| Error messages | Plain language; no codes shown | OK |
| Support | No contact, FAQ or "report a problem" | P1 (Play listing needs a support email anyway) |
| Language | English only; ₹ only | P2 |
| Accessibility of the app itself (TalkBack labels, text scaling) | Not audited on a device | P1 |

## I. Release-readiness checklist

- [x] Target API 36
- [x] No `QUERY_ALL_PACKAGES`
- [x] HTTPS only, backups off, no secrets in APK
- [x] All automated tests pass (section "Tests")
- [ ] Accessibility disclosure + consent screen
- [ ] Tamper protection optional (R1) and Play confirmation
- [ ] In-app privacy text and Accessibility description corrected
- [ ] Privacy policy published and linked in app
- [ ] Payment model decided (or amount clearly not charged in v1)
- [ ] Final application ID chosen
- [ ] Upload key created, backed up; Play App Signing
- [ ] App Bundle built and tested from Play internal track
- [ ] Production API address in release builds
- [ ] Source in git with a private remote backup
- [ ] Production Supabase project, paid plan, secrets, migrations
- [ ] Retention and deletion process
- [ ] Monitoring and alerts
- [ ] Play Console: Accessibility declaration + video, foreground-service declaration + video, Data Safety, content rating, target audience, store listing, reviewer instructions
- [ ] Closed test: 12 testers, 14 days (if the account is a new personal account)
- [ ] Tested on Android 16 and at least 2 other manufacturers

## J. Prioritised remediation plan

### P0 – must fix before Play submission

| # | Item | Size |
|---|---|---|
| P0-1 | Make tamper protection optional and reword it; review `manageSpaceActivity`; get Play's view (R1) | Small code change + your decision |
| P0-2 | Accessibility prominent disclosure + Agree/No thanks screen; update `accessibility_description` | Small |
| P0-3 | Correct Settings → Privacy text and setup card to match what 2.8.0 sends | Small |
| P0-4 | Write and host the privacy policy; link it in the app and Play Console | Document + 1 link |
| P0-5 | Decide the payment model for v1 (section 9). If undecided: ship without charging and say so plainly | Your decision + Google/lawyer |
| P0-6 | Final application ID | Your decision, 1 line |
| P0-7 | Upload key, Play App Signing, App Bundle | You, guided |
| P0-8 | Release build must use the production API address, not `commit-dev` | Small + needs P1-1 |
| P0-9 | Put the project in git with a private remote | Small |

### P1 – should fix before public release

| # | Item |
|---|---|
| P1-1 | Production Supabase project (paid plan, own secrets and recovery key, 4 migrations, function) |
| P1-2 | Retention period + deletion: in-app "delete my data" request and a server process; then answer "Yes" in Data Safety |
| P1-3 | Monitoring: uptime check, log alerts, backup confirmation |
| P1-4 | Close the offline clear-data/uninstall escape route with a server rule (open since Phase 5) – this also supports P0-1 |
| P1-5 | Pin compileSdk/targetSdk/minSdk in the project |
| P1-6 | Consent-style explanations before Usage access and overlay settings |
| P1-7 | Device testing: Android 16, Xiaomi/Samsung/Oppo, TalkBack, large text |
| P1-8 | Support email, FAQ, first-launch-offline message |
| P1-9 | Play Integrity check before any real payment |

### P2 – can fix after launch

| # | Item |
|---|---|
| P2-1 | Certificate pinning |
| P2-2 | Dart obfuscation |
| P2-3 | Nightly server sweep for overdue challenges |
| P2-4 | Remove stray manifest attribute and unused `upi://` query (if no UPI payments) |
| P2-5 | Tablet/foldable layouts |
| P2-6 | Hindi and other languages |

## Tests (run on the audit date, nothing modified)

| Suite | Result |
|---|---|
| Flutter unit/widget tests | 226 passed, 3 skipped (the live tests) |
| Flutter end-to-end against local handler + database | 3 passed |
| Static analysis (`flutter analyze`) | No issues |
| Backend Phase 1 | 10/10 |
| Backend Phase 2 (database) | 131/131, guard PASS |
| Backend Phase 3 | 48/48 |
| Backend Phase 5 | 38/38 |
| Edge Function type check (Deno) | Clean |
| Android unit tests (`testDebugUnitTest`) | 3/3 |
| Android instrumented/UI tests | None exist |
| Android lint | Not run |

## What this audit could not verify

- Anything in your Play Console account (account type, whether the 12-tester rule applies, whether `com.commit.app` is free).
- Behaviour on an Android 16 device or on other manufacturers.
- How a Play reviewer will actually judge R1 and the payment model.
- Supabase plan, region and backup settings (dashboard only).

## Sources (official, read 4 Oct 2026)

- [Target API level requirements](https://support.google.com/googleplay/android-developer/answer/11926878?hl=en)
- [Use of the AccessibilityService API](https://support.google.com/googleplay/android-developer/answer/10964491?hl=en)
- [Permissions and APIs that Access Sensitive Information](https://support.google.com/googleplay/android-developer/answer/16558241?hl=en)
- [Preview of upcoming changes to that policy (effective 27 Jan 2027)](https://support.google.com/googleplay/android-developer/answer/16909972?hl=en_mt)
- [Best practices for prominent disclosure and consent](https://support.google.com/googleplay/android-developer/answer/11150561?hl=en)
- [User Data policy](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en)
- [Data safety form](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en)
- [Payments policy](https://support.google.com/googleplay/android-developer/answer/9858738?hl=en)
- [Real-Money Gambling, Games, and Contests](https://support.google.com/googleplay/android-developer/answer/9877032?hl=en)
- [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/16559646?hl=en)
- [Foreground service declaration](https://support.google.com/googleplay/android-developer/answer/13392821?hl=en)
- [Mobile Unwanted Software](https://support.google.com/googleplay/android-developer/answer/9970222?hl=en)
- [App testing requirements for new personal developer accounts](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en)
- [Android 16 behaviour changes for apps targeting API 36](https://developer.android.com/about/versions/16/behavior-changes-16)
