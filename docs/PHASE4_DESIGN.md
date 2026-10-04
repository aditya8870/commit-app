# Commit – Phase 4: accountless installation in the Flutter app

App version 2.7.0. Backend unchanged (Phases 1–3 as deployed). No challenge API, no sync, no payments, no new screens.

## 1. What the app now does

On start, and each time it comes to the front, the app runs one background task:

1. **Already registered?** Read the installation ID and credential from encrypted storage. If both are there, stop: no network is used.
2. **Not registered:** generate a 256-bit credential, save it as "pending", ask Android for the recovery hash, and call `POST /v1/installations`.
3. **Server says "recovery required"** (a reinstall): call `POST /v1/installations/recover` with the same new credential. The server returns the existing installation ID.
4. **Save** credential and ID to encrypted storage; remove the pending copy.
5. **Check once per app run:** `GET /v1/installations/me` with the credential in a header. If the server reports the recovery key is out of date, call `POST /v1/installations/me/recovery`.

Nothing in the UI waits for this, and nothing in blocking, challenges, countdown or emergency access uses it. With no network the app behaves exactly as 2.6.0.

## 2. Files and responsibilities

| File | Role |
|---|---|
| `lib/core/installation.dart` | `InstallationIdentity`, `InstallationStatus`, `ApiException` (codes only, never secrets) |
| `lib/data/api_client.dart` | The single request path: HTTPS only, headers for credentials, 15 s timeout, error parsing. `HttpApiTransport` uses `dart:io` |
| `lib/data/installation_service.dart` | Registration, recovery, verification, retry timing |
| `lib/platform/installation_platform.dart` | What is needed from Android: encrypted read/write/delete, recovery hash, versions |
| `android/.../InstallationSupport.kt` | `SecureStore` (AES-256-GCM, key in Android Keystore) and `RecoveryMaterial` (the hash) |
| `android/.../MainActivity.kt` | Five new channel methods that call the two objects above |
| `lib/main.dart`, `lib/app.dart` | Start the background task at launch and on resume |

`CommitController`, `PlatformBridge`, the engine and every blocking service are untouched.

## 3. Contract with the server (unchanged from Phase 3)

- Credential: 32 random bytes from the system's cryptographic source, sent as 43 base64url characters.
- Recovery value: `SHA-256("commit-recovery-v1:" + ANDROID_ID)` as 64 hex characters, computed in Kotlin. The raw identifier never reaches Dart, storage, logs or the network.
- Signed requests: `Authorization: Bearer <credential>` and `X-Installation-Id: <id>`.

## 4. Behaviour in each situation

| Situation | What happens |
|---|---|
| First launch, online | Registers once; ID and credential stored |
| First launch, offline | App works as before. Tries again when the app next comes to the front, at most once a minute |
| Later launches | No registration request. One `/me` check per app run; failure is ignored |
| App killed between the server's answer and saving | The pending credential is re-sent; the server returns the same installation |
| Many starts at once | They share one attempt |
| Reinstall | New credential, recovery, same installation ID |
| Phone has no usable Android ID | Registers without recovery; a reinstall then becomes a new installation |
| App data cleared | Same as reinstall (encrypted storage is cleared too; the Android ID is unchanged) |
| Server rejects the stored credential (401) | Identity reset and recovered. Challenge data on the phone is not touched |
| Rate limited (429) | Waits as long as `Retry-After` says |
| Server error / misconfigured (5xx) | Retries after 60 s |
| Request refused as invalid (4xx) | Retries after 15 min; never loops |
| Malformed answer | Ignored; nothing stored |
| Encrypted storage unavailable | Does nothing, rather than risk a second installation |

## 5. Privacy and security review

| Topic | Finding |
|---|---|
| Secure storage | AES-256-GCM; the key is generated inside Android Keystore and cannot be exported. Only ciphertext is on disk, in its own preferences file. Not SharedPreferences in plain text, not the app's JSON state |
| Randomness | `Random.secure()` (system CSPRNG). A test fails if a predictable `Random()` appears |
| Credential exposure | Only in the registration body (once) and in the `Authorization` header, over HTTPS. Never in an address: the client refuses any path with a query |
| Logs | The identity code has no print or log call (tested). Errors carry a code only |
| Screenshots / debug output | The credential and ID are never shown on any screen |
| Backup | `allowBackup=false` and extraction rules already exclude everything, so the encrypted file is not backed up; its key could not be restored anyway |
| Reinstall | Keystore key and storage are wiped by Android; recovery restores the same installation |
| App data clearing | Same as reinstall. During a challenge, Android's "Clear data" is already replaced by Commit's own screen |
| Concurrent initialisation | Single-flight; plus the pending credential makes a repeat harmless |
| HTTP vs HTTPS | The client refuses non-HTTPS addresses; the manifest sets `usesCleartextTraffic=false` |
| Certificates / hostname | Platform default validation. No override exists in the code (tested). No pinning, see section 8 |
| Redirects | Not followed, so the credential header cannot be carried to another host |
| Malformed responses | Size capped at 64 KB; must be a JSON object; the ID must be a UUID |
| Replay | Protected in transit by TLS. Registration and recovery are idempotent for the same credential |
| Credential replacement after recovery | The new credential is stored before the ID; the old one is rejected by the server (tested end to end) |
| Rooted phone | Can read its own credential and fake its Android ID. Not preventable |
| Personal data | None added. No name, email, phone, contacts, location or advertising ID |

What leaves the phone in this phase: the credential (once, at registration), the 64-character recovery hash, the app version and the Android version.

## 6. Permission and manifest changes

- Added `android.permission.INTERNET`.
- Added `android:usesCleartextTraffic="false"`.
- No other permission. No `ACCESS_NETWORK_STATE`.

## 7. Dependencies

No new Flutter or Android runtime dependency.

| Need | How |
|---|---|
| HTTPS | `dart:io` `HttpClient` (part of Dart) |
| Encrypted storage | Android Keystore + `javax.crypto` (part of Android) |
| SHA-256 | `java.security.MessageDigest` (part of Android) |
| Random | `dart:math` `Random.secure()` |
| JUnit 4.13.2 | Test only (`testImplementation`); not in the app |

`flutter_secure_storage` was considered. It wraps the same Keystore mechanism, but it would be the project's first plugin; about 60 lines of native code using platform APIs keep the app dependency-free. If you prefer the package, it can replace `SecureStore` behind the same interface.

## 8. Unresolved decisions

1. **Starting a challenge still does not require registration.** The approved architecture says internet is required to start a challenge once the challenge API is live; that belongs to the challenge phase.
2. **Certificate pinning** is not done. It protects against a mis-issued certificate but can lock users out when Supabase rotates certificates.
3. **Production address.** The app points at `commit-dev`. A release for another server is built with `--dart-define=COMMIT_API_BASE=...`.
4. **Privacy policy** text is needed before any public release; the in-app Privacy text was updated to stay true.

## 9. Rollback

- The server needs no rollback: this phase changed nothing there.
- Android will not install 2.6.0 over 2.7.0. To roll back, either uninstall first (after turning tamper protection off), or install a newer build with the single `installation.start()` call removed from `lib/main.dart`.
- Rows created in `installations` by test devices are harmless. They can be deleted in the SQL Editor (an installation with no challenges can be deleted).
- Local challenge data is unaffected in either direction: the identity lives in a separate encrypted file.
