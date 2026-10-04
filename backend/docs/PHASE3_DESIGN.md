# Commit backend – Phase 3 design: installations, recovery, request authentication

Status: implemented and tested locally. **Not deployed. Not applied to Supabase.** No Flutter or Android change.

## 1. What Phase 3 adds

| Piece | What |
|---|---|
| Migration `20261005090000_installation_api.sql` | 1 table (`rate_limits`), 1 column (`installations.recovery_key_version`), 6 server-only database functions |
| Edge Function `api` | 4 new routes; `/v1/time` unchanged |
| Tests | 48 API tests against a real local database, plus the earlier 10 + 131 |

No accounts, no Supabase Auth, no Google sign-in, no payment code.

## 2. Identity

| Value | Made by | Stored on phone | Stored on server |
|---|---|---|---|
| Installation ID (UUID) | Server | Yes | Yes |
| Installation credential (32 random bytes = 256 bits, sent as 43 base64url characters) | Phone | Yes, encrypted storage | Only `SHA-256(credential)` |
| Recovery material = `SHA-256("commit-recovery-v1:" + ANDROID_ID)` | Phone | Recomputed when needed | Only `HMAC-SHA-256(recovery key, "device:" + material)` plus the key's version number |

The raw `ANDROID_ID` never leaves the phone. The recovery keys live only in Supabase's secret store (section 5a).

## 3. API

Every answer is JSON and includes `serverTime` and `epochMs`. Errors are `{code, message, retryable, serverTime, epochMs}`.

### POST /v1/installations  (public)
Request body:

    { "credential": "<43 chars>", "recoveryMaterial": "<64 hex>" | null,
      "appVersion": "2.6.0", "androidVersion": "14" }

| Result | Status | Body |
|---|---|---|
| New installation | 201 | `{ installationId }` |
| Same credential sent again | 200 | `{ installationId }` (same one) |
| This phone already has an installation | 409 `RECOVERY_REQUIRED` | no ID; nothing created |
| Bad input, or body contains `installationId`/`id` | 422 `VALIDATION_FAILED` | |
| Too many from this network address | 429 `RATE_LIMITED` + `Retry-After` | |

### POST /v1/installations/recover  (public)
Same body; `credential` is the NEW credential and `recoveryMaterial` is required.

| Result | Status | Body |
|---|---|---|
| Recovered | 200 | `{ installationId, recoveryCount, hasActiveChallenge }` |
| Same new credential sent again | 200 | same, count not increased |
| No installation for this phone | 404 `RECOVERY_NOT_FOUND` | nothing created |
| Installation suspended | 403 `INSTALLATION_SUSPENDED` | |
| New credential belongs to another installation | 409 `CREDENTIAL_IN_USE` | |
| Too many | 429 `RATE_LIMITED` | |

Recovery replaces the stored credential hash, so the old credential stops working at once. The installation ID, its challenges and their times are untouched. `recovery_count` and `last_recovered_at` are set by a database trigger.

### GET /v1/installations/me  (signed)
Returns `{ installationId, status, recoveryCount, recoveryUpToDate, createdAt }`. `recoveryUpToDate: false` tells the app to call the next route. It exists so the credential check can be exercised and tested before any challenge route exists.

### POST /v1/installations/me/recovery  (signed)
Body `{ "recoveryMaterial": "<64 hex>" }`. Moves this installation's device hash to the current recovery key version, or stores one if it had none.

| Result | Status |
|---|---|
| Moved, stored, or already current | 200 `{ recoveryUpToDate: true, changed }` |
| Device does not match what is stored, its key version is retired, or the device belongs to another installation | 409 `RECOVERY_NOT_UPDATED` (one answer for all three) |
| Bad or missing credential | 401 |

## 4. Authenticating later requests

    Authorization: Bearer <credential>
    X-Installation-Id: <installation ID>

- Sent only in headers, only over HTTPS. Never in the URL, never in a body, never logged.
- The server hashes the credential and looks for a row where BOTH the ID and the hash match.
- Every failure gives the identical 401, so nothing reveals whether an ID exists.
- A suspended installation gets 403.
- Changing calls will additionally carry an `Idempotency-Key` (Phase 4), which is what makes a replayed request harmless.

Why not signed requests: verifying a signature made with the credential would require the server to keep a usable copy of it, which is weaker than keeping only a hash. See "Unresolved decisions".

## 5. Rate limiting

One table, `rate_limits(bucket, subject, window_start, count)`, and one function that counts an attempt and says whether it is allowed. Fixed windows. `subject` is always a hash.

| Bucket | Subject | Limit | Depends on the caller's address? |
|---|---|---|---|
| `register_ip` | keyed hash of the network address | 10 per hour | Yes |
| `register_global` | everyone | 500 per hour | No |
| `recover_ip` | keyed hash of the network address | 10 per hour | Yes |
| `recover_global` | everyone | 500 per hour | No |
| `recover_device` | the device hash | 5 per day | No |
| `auth_fail_ip` | keyed hash of the network address (failed sign-ins only) | 20 per 10 minutes | Yes |
| `request_installation` | hash of the installation ID | 120 per minute | No |

A blocked attempt changes nothing and answers 429 with `Retry-After`.

### Where the network address comes from

- **Source used:** the LAST entry of the `X-Forwarded-For` header.
- **Why the last:** each proxy appends the address it received the request from. The last entry is therefore written by the proxy nearest the server. The FIRST entry is whatever the caller typed, and is never used.
- **Not used:** `X-Real-IP`, `CF-Connecting-IP`, `Forwarded`, or any other header, because a caller can send those.
- **What Supabase documents:** a Supabase maintainer states that Edge Functions receive the client address in `X-Forwarded-For`. Supabase does not document whether a caller-supplied value in that header is removed, so this design does not rely on it.
- **Fail-safe behaviour:**
  - Missing or malformed header: all such callers share one bucket, so the limit becomes stricter, never looser.
  - If the last entry turns out to be a Supabase proxy address shared by everyone: again one shared bucket, stricter.
  - If the address were somehow forgeable anyway: the `*_global` caps, `recover_device` and `request_installation` still hold, because none of them use the address.
- **Conclusion:** the per-address limits are a convenience against casual abuse, not a security boundary. The boundaries are the address-independent limits.

The cost of the global caps: a flood of registrations can block new installs for up to an hour. Existing installations are unaffected, because signed requests are limited per installation.

## 5a. Recovery key rotation

Keys are versioned. The server reads them from Supabase's secret store:

| Secret name | Meaning |
|---|---|
| `COMMIT_RECOVERY_SECRET_V1`, `_V2`, ... | One key per version, each at least 32 characters, all different |
| `COMMIT_RECOVERY_CURRENT_VERSION` | The version used for every new hash |

Each installation stores which version produced its device hash (`recovery_key_version`).

How a rotation runs:

1. **Add** `COMMIT_RECOVERY_SECRET_V2` and set `COMMIT_RECOVERY_CURRENT_VERSION=2`. Version 1 stays in place.
2. **Window.** Both versions are accepted.
   - New installations get version 2.
   - Recovery finds a phone under either version and moves it to version 2 in the same step.
   - Registration recognises a known phone under either version, so no duplicate is created.
   - Each running app sees `recoveryUpToDate: false` and calls `POST /v1/installations/me/recovery`, which moves it to version 2. It must present the same device and a valid credential.
3. **Check** how many installations are still on version 1:
   `select recovery_key_version, count(*) from public.installations group by 1;`
4. **Retire** by deleting `COMMIT_RECOVERY_SECRET_V1` once that count is acceptable.

**Decided: the rotation window is 90 days.** The previous key stays in place for 90 days after a new version becomes current, and is retired after that.

Properties:

- Rotation never signs anyone out: credentials do not depend on the recovery key.
- Security is not weakened: every stored hash is still keyed, the raw identifier is still never sent, and moving a hash requires proving both the credential and the same device.
- The server does not accept a client-supplied installation ID as proof of identity. Recovery depends on the keyed recovery value and credential controls described in this design; a modified client or compromised/rooted device may bypass device-level assumptions.
- An installation that never opened the app during the whole window keeps working, but loses reinstall recovery when the old key is retired. This is the one unavoidable cost, because the server does not keep anything it could re-hash on its own.
- A wrong configuration (no key for the current version, a short key, the same key under two versions) makes registration and recovery answer 500 and store nothing.

## 6. Security review

| Topic | Finding |
|---|---|
| Credential entropy | 256 random bits. The server refuses anything that is not exactly 43 base64url characters or is obviously non-random. Guessing is not feasible |
| Hashing | SHA-256 of a 256-bit random value. A slow password hash is not needed, because there is nothing to guess |
| Replay | TLS prevents capture in transit. A captured request could be replayed only by someone who already has the credential. Changing calls get idempotency keys in Phase 4 |
| Rotation on recovery | The old hash is overwritten in the same statement, so the old credential is dead immediately. Tested |
| Recovery abuse | Anyone who knows a phone's per-app `ANDROID_ID` can take over that installation. It needs root or the phone itself. The effect is a denial of service (the real app is signed out until it recovers again), limited to 5 per day per phone. It does not expose data: recovery returns only an ID and a yes/no |
| Brute force | Credential: infeasible. Recovery material: `ANDROID_ID` has 64 bits, and attempts are limited per address |
| Enumeration | Sign-in failures are indistinguishable. Registration and recovery do reveal whether a given device hash is known; that requires already knowing the device's identifier |
| Timing | Lookups compare hashes inside the database index. A timing difference cannot be steered without inverting SHA-256, so no constant-time compare is needed in function code, and none is done there |
| Logging | The function logs only the method and path on an unexpected error. Bodies and headers are never logged |
| Secrets | The versioned recovery keys and the service role key are read from the environment. With invalid keys, registration and recovery answer 500 and store nothing. No fallback value exists |
| Rooted device | Can read its own credential and fake its `ANDROID_ID`. Cannot be prevented by the server |
| Stolen credential | Gives control of that one installation until the phone recovers or the installation is suspended |
| Database leak | Exposes hashes only. Credential hashes cannot be reversed. Device hashes cannot be recomputed without the server secret |
| App roles | Cannot execute any `api_*` function or read `rate_limits`. Tested |

## 7. Assumptions

1. Supabase gives Edge Functions `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` automatically. To be confirmed at deployment.
2. Supabase appends the caller's address to `X-Forwarded-For`. If it does not, the per-address limits collapse into one shared bucket (safe, but strict); see section 5.
3. The database functions are called through Supabase's REST interface. That adapter (about 15 lines) is the only code not exercised by the local tests.

## 8. Unresolved decisions

1. **Request signing with a device key pair** (the phone signs each request; the server stores a public key). Stronger against a leaked credential in transit, but it replaces the approved credential model. Not done.
2. **Play Integrity check on registration**, to make scripted registrations harder. Later phase.
3. **Retention**: when to delete installations that never return.
