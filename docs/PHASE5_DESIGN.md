# Commit – Phase 5: Challenge API and offline synchronisation

Status: built and tested locally. **Nothing is deployed, no SQL is applied, no payment exists.**
App version: 2.8.0 (build 15). Backend: 1 new migration (functions only) + updated Edge Function `api`.

## 1. Design in short

| Question | Who decides |
|---|---|
| Is an app blocked right now? Countdown, emergency timer, interruption detection, recovery after restart | The phone (unchanged) |
| Challenge ID, start time, end time, status, emergency-use record, future payment state | The server |

- Starting a challenge needs internet and a registered installation. The phone sends only what the user chose (apps, minutes, amount, emergency settings, consent version). The database clock sets start and end. The phone stores a copy.
- After that the phone needs no internet. Blocking never waits for, or stops because of, the server.
- Things that happen on the phone (emergency use, force stop, protection lost, clock jump, restore) go into a saved queue and are sent when a connection exists. Each item has its own ID, so sending it twice changes nothing.
- Completion is decided by the database clock. Any request after the end time completes the challenge on the server ("lazy completion"); no scheduled job is needed.
- Ending early is always refused (`PAYMENTS_UNAVAILABLE`). The status `ended_early` cannot be reached: the database requires a successful payment row and none can exist.
- Whenever the server answers, its time replaces the phone's trusted clock (new native call `anchorClock`). A wrong phone clock is therefore corrected at the next contact.

## 2. API contract

Base: `https://sgnmsjduvffrxkjieyfy.supabase.co/functions/v1/api`. Every endpoint below needs `Authorization: Bearer <credential>` and `X-Installation-Id`. The installation comes only from these headers; an installation ID in a body is rejected. Every answer carries `serverTime` and `epochMs`. Limit: 120 requests per minute per installation.

Challenge object: `id, status (active|completed|ended_early|cancelled), startTime, endTime, actualEndTime, durationMinutes, amountRupees, emergencyLimit, emergencyMinutes, emergencyUsed, interruptionCount, consentVersion, consentAcceptedAt, createdAt, apps[{packageName, appName}], payment{status:"not_started", available:false}`.

| Endpoint | Sends | Success | Controlled errors |
|---|---|---|---|
| `POST /v1/challenges` | Header `Idempotency-Key` (16–128 chars). Body: `apps`, `durationMinutes` (1–43200), `amountRupees` (100–10000), `emergencyLimit` (0–3), `emergencyMinutes`, `consentVersion`, `consentAccepted: true` | 201 new, 200 same key again | 400 `IDEMPOTENCY_KEY_REQUIRED`, 422 `VALIDATION_FAILED` (also if start/end/status/ID is sent), 422 `CONSENT_REQUIRED`, 409 `ACTIVE_CHALLENGE_EXISTS`, 409 `IDEMPOTENCY_MISMATCH` |
| `GET /v1/challenges/active` | – | 200 `{challenge}` or `{challenge: null}` | – |
| `GET /v1/challenges/history?limit=&before=` | limit 1–50 (default 20) | 200 `{items, nextBefore}` newest first | 422 |
| `GET /v1/challenges/{id}` | – | 200 `{challenge}` | 404 `NOT_FOUND` (also for another installation's challenge) |
| `POST /v1/challenges/{id}/complete` | – | 200 completed (also if already completed) | 409 `TOO_EARLY` + `secondsRemaining`, 409 `CHALLENGE_NOT_ACTIVE`, 404 |
| `POST /v1/challenges/{id}/emergency` | `useId` (UUID from phone), `startedAt`, `minutes` | 201 recorded, 200 duplicate | 409 `EMERGENCY_LIMIT_EXCEEDED`, 409 `CHALLENGE_NOT_ACTIVE` (kept as a history event), 422, 404 |
| `POST /v1/challenges/{id}/end-early` | Header `Idempotency-Key` | never succeeds in this phase | 409 `PAYMENTS_UNAVAILABLE` (`paymentRequired: true`, `amountRupees`), 409 `TOO_CLOSE_TO_END` (< 60 s left), 409 `CHALLENGE_NOT_ACTIVE`, 404 |

Two endpoints beyond the seven you listed (needed for safe offline sync, please confirm):

| Endpoint | Why |
|---|---|
| `GET /v1/challenges/registrations/{key}` | After a lost answer, asks "did my create request make a challenge?" without creating one |
| `POST /v1/challenges/{id}/events` | Uploads up to 100 phone observations (`force_stopped`, `protection_lost`, `protection_restored`, `accessibility_off`, `tamper_protection_off`, `restored_on_device`, `clock_jump`); duplicates ignored |

## 3. Database changes

Migration `20261006090000_challenge_api.sql`: **12 new server functions only.** No table, column, trigger, policy or payment change. All 12 are callable by `service_role` only. Rollback = drop the 12 functions.

## 4. Offline and restart behaviour

| Situation | Behaviour |
|---|---|
| App restart | Challenge read from the phone's saved state; blocking continues; sync runs in the background |
| Phone restart | Same; boot receiver restarts blocking as before |
| Force stop | Blocking returns when the app/service starts again (as in 2.7.0); the event is queued and uploaded |
| Network loss | Nothing changes on the phone. Queue is kept on disk and retried every ~15 s while the app is open and on every resume |
| Server unavailable | Same as network loss. A new challenge cannot be started; the user sees "The server could not be reached. Nothing was started." |
| App data cleared / reinstall | Installation is recovered (Phase 3/4), then `GET active` restores the running challenge with the original end time and emergency count; `restored_on_device` is recorded |
| Recovered installation | Same as above |
| Stale local challenge (server already completed) | Server status replaces the local one |
| Challenge made before 2.8.0 (local only) | Finishes locally as before; never uploaded |

## 5. Conflict rules

| Conflict | Result |
|---|---|
| Local ACTIVE, server COMPLETED | Server wins: marked completed |
| Local ACTIVE, server ENDED_EARLY | Server wins (cannot occur in this phase) |
| Server has an active challenge, phone has none | Restored on the phone and blocked again |
| Phone has a challenge, server has none | Phone keeps blocking until its end time; nothing is uploaded or invented |
| Create sent twice | Same idempotency key returns the same challenge; a different key gets `ACTIVE_CHALLENGE_EXISTS` |
| Emergency reported twice | Same `useId` is counted once |
| Emergency above the limit | Refused by the server; the phone already enforces the limit locally |
| Completion reported late | Fine: the server completed it by its own clock at the first contact after the end time |
| Completion reported early | `TOO_EARLY`; stays active |
| Phone clock ahead (phone thinks it is finished) | On contact the server time is adopted, the challenge becomes active again, `clock_jump` is recorded |
| Phone clock behind | Server completion wins |

## 6. Flutter changes

New: `lib/data/http_backend.dart` (the only file that knows addresses and JSON), `lib/data/server_time.dart`.
Changed: `lib/data/api_client.dart` (query, idempotency header, server-time callback), `lib/core/installation.dart` (error codes), `lib/data/installation_service.dart` (`loadStored`), `lib/main.dart` (wiring), `lib/core/backend.dart` (2 event names), `lib/core/commitment.dart` (`reactivated`), `lib/data/commit_controller.dart` (3 small additions: revive after a clock jump, record a restore, accept server "completed"), `lib/platform/platform_bridge.dart`, Kotlin `NativeStore.kt` + `MainActivity.kt` (`anchorClock`). No screen was changed.

## 7. Security review

| Check | Result |
|---|---|
| Installation authentication on every challenge endpoint | Yes |
| Client-supplied installation ID trusted | No; rejected if present in a body |
| Other installation's challenge | 404, identical to "does not exist" |
| Start/end/status from client | Rejected with 422 |
| Timestamps | Database clock only |
| State machine | Enforced by existing database triggers; terminal states cannot change |
| Idempotency | Create and end-early by header key; emergency and events by their own IDs |
| Logging | Method and path only; no bodies, credentials or IDs |
| Secrets in the APK | None (unchanged) |
| Payment | No code path can report success; `payments` stays empty |
| Malformed server answer | Refused by the app, never stored |

Known limits (not new, stated plainly):

1. **Clearing app data or uninstalling while offline removes blocking until Commit is opened online again.** The server still has the challenge and will later mark it completed. This is the main remaining escape route; closing it needs a server-side rule (for example: a challenge with a `restored_on_device` or long silence is not counted as cleanly completed). Decision needed before payments.
2. A rooted phone or modified app can ignore local blocking. The server record cannot prevent that.
3. Phone observations (emergency use, force stop) are reported by the phone and can be withheld by a modified app.
4. The clock correction uses the server answer over HTTPS; answers slower than 5 s are ignored.

## 8. Deployment order (only after your approval)

1. SQL Editor: run `20261006090000_challenge_api.sql` once.
2. Run `tests/db/verify_phase5.sql`; all 11 rows must show `ok = true`.
3. Replace Edge Function `api` with the new `index.ts`, Verify JWT stays off, deploy.
4. Open `/v1/time`: must still answer.
5. Install the 2.8.0 APK and run `PHASE5_DEVICE_TEST.md`.

Migration before function, function before APK.

## 9. Rollback

| Layer | How |
|---|---|
| App | Install 2.7.0 again (challenges become local-only as before) |
| Edge Function | Redeploy the Phase 3 `index.ts` |
| Database | `drop function` for the 12 new functions; no data is touched. Rows created in `challenges` during testing can stay |
