# Commit 2.2.0 — payment readiness review

Review date: 4 Oct 2026. Scope: the code as shipped in 2.2.0 (about 5,900 lines of
Dart and Kotlin). Nothing was changed for this review.

Basis: I read the payment, state and storage code paths again and checked the
manifest and build settings. Statements about Google Play and Razorpay come from
their public documentation (linked at the end). I am not a lawyer or a payments
compliance adviser; the regulatory points need confirming with the provider you
choose and, ideally, a professional.

## Verdict

**The app-side structure is suitable for a real provider. The app as a whole is
not ready for real money**, for three reasons:

1. There is no backend, and four things that are decided on the phone today must
   be decided on a server.
2. One retry path can charge twice (B1 below).
3. **Google Play's payments policy may decide which provider you are allowed to
   use.** Its list of things that must use Google Play's billing system includes
   "app functionality or content". Paying to end a challenge and unlock apps
   plausibly falls under that. If so, a direct Razorpay/Cashfree checkout would
   not be allowed in a Play Store build. This needs settling before any
   provider work (section H1).

---

## A. What is already production-ready

| Area | State |
|------|-------|
| Seam for a provider | `PaymentService` (`isConfigured`, `pay`, `verify`) is the only place a provider touches. UI and controller do not know which provider it is. |
| Explicit consent path | End Challenge → amount shown → Continue to Payment → Pay. Nothing charges on any other path. |
| Verified-success rule | The challenge ends only when `verify` returns success. A checkout "success" alone is rejected (tested). |
| Unknown outcomes | INITIATED, PENDING, VERIFICATION_FAILED and NETWORK_ERROR only re-check; they never open a second checkout (tested). |
| Crash/restart during payment | INITIATED is written to disk before the checkout opens; reconciled on app start and on resume (tested). |
| Double tap | Busy flag is set before the first wait (tested). |
| Challenge persistence | Apps, end time, emergency uses, amount and payment state survive restart and reboot (tested, and passed on your phone). |
| No automatic charge | Force stop, restart, lost permission, crash and offline never charge and never end a challenge (tested). |
| No credentials stored | Payment record holds reference, amount, status, transaction ID and timestamps only (tested). |
| Honest UI | With no provider the app says so and offers no Pay button. |

## B. What needs to change in the app

Ordered by risk.

**B1. Retry after "failed" or "cancelled" can double-charge.**
Today those two statuses allow a fresh checkout without asking the server first.
With UPI in particular, a payment can be debited while the app is told it
failed. Rule to adopt: *every* new attempt is preceded by a server status check,
whatever the app last saw.

**B2. Payment reference is generated on the phone.**
`commit-<microseconds>-<random>` is unique enough locally, but it is not issued
by a server, not tied to a user, and predictable. The provider order must be
created by the backend, and the app must only receive the order ID.

**B3. Amount is taken from local storage at pay time.**
The amount must come from the server's copy of the challenge, fixed when the
challenge was created. The phone only displays it.

**B4. Android backup is on by default.**
The manifest does not set `allowBackup`, so Android may back up and later
restore the challenge file (for example after a reinstall or on a new phone).
That can resurrect an old challenge or an old payment state. Turn backup off
for this file.

**B5. "Reset local data" deletes payment records.**
It removes ended-early challenges together with their transaction IDs. Once
money is involved, paid records must be kept on the phone (or at least always
be retrievable from the server).

**B6. Late payment has no refund path.**
If a payment is verified after the challenge has already finished by itself,
the app records it (state PAYMENT_VERIFIED) but nothing gives the money back.
The 60-second cut-off is far too short for UPI; see section E.

**B7. Pending has no time limit.**
A PENDING payment stays pending until the user opens the app. It needs polling
with a limit and an order expiry.

**B8. The blocker can break a checkout.**
- If the user blocked their UPI app or browser, the payment cannot be completed
  because Commit blocks it.
- When a blocked app comes to the front, Commit reopens itself with a flag that
  closes any screen above its main screen, which would close a provider's
  checkout screen.
Payment apps need to be excluded from selection or allowed for the length of a
checkout.

**B9. No user or device identity.**
There are no accounts. A backend cannot tell whose challenge or payment is
whose. At minimum: an install ID issued by the server plus a token; better: a
phone-number login.

**B10. Release signing.**
The APK is signed with a debug key. A real release key is needed, and changing
keys forces every tester to uninstall first (losing data). Do this before real
users exist.

**B11. Smaller items.**
- Storage schema version exists but there is no migration code.
- Internet permission is absent; the in-app Privacy text says the app does not
  use the internet. Both change with payments.
- History and interruption lists are kept in one growing file with no cap.

## C. What must move to a backend

| Decision | Today | Must be |
|----------|-------|---------|
| The challenge exists, its amount and its end time | Phone only | Registered on the server when it starts; server copy is the reference |
| Creating the payment order | Not done | Server, using the server's amount |
| "Is this paid?" | `verify` on the phone (not connected) | Server: provider signature check plus provider webhook |
| Current time for "ended early vs completed" | Phone clock (tamper-resistant within one boot only) | Server clock |
| Refunds and reconciliation | None | Server |
| Provider secret key and webhook secret | None | Server only |
| Fraud and abuse limits | None | Server |

What stays on the phone: blocking, emergency access, the timer display, and the
unlock itself. **The unlock is local and always will be**: someone with a
modified phone can unlock without paying. The payment is a commitment device,
not a lock; the backend makes the money side correct, it cannot make the block
unbreakable.

## D. Recommended database structure

Five tables. Types are indicative.

**users**: `id` (uuid) · `created_at` · `phone_or_email` (nullable) · `status`

**devices**: `id` · `user_id` · `install_id` (server-issued) · `platform` ·
`app_version` · `integrity_verdict` (latest device attestation) · `last_seen_at`

**challenges**: `id` (uuid, server-issued) · `user_id` · `device_id` ·
`apps` (json list of package + name) · `start_at` · `end_at` (server time) ·
`duration_minutes` · `amount_paise` (integer) · `currency` ·
`emergency_limit` · `emergency_minutes` · `emergency_used` ·
`status` (ACTIVE, COMPLETED, ENDED_EARLY, CANCELLED) ·
`actual_end_at` · `interruption_count` · `interrupted_seconds` ·
`created_at` · `updated_at`

**payments**: `id` · `challenge_id` (unique: one order per challenge) ·
`provider` · `provider_order_id` (unique) · `provider_payment_id` (unique,
nullable) · `amount_paise` · `currency` ·
`status` (CREATED, PENDING, CAPTURED, FAILED, CANCELLED, EXPIRED,
REFUND_PENDING, REFUNDED) · `expires_at` · `captured_at` ·
`refund_id` · `refund_reason` · `created_at` · `updated_at`

**payment_events** (append-only audit): `id` · `payment_id` ·
`source` (webhook, client, poll, admin) · `provider_event_id` (unique, for
de-duplicating webhooks) · `type` · `payload` (json) · `received_at`

Money is stored as integer paise, never as decimals. Nothing in any table holds
card numbers, CVV, UPI PIN or bank credentials; the provider holds those.

## E. Recommended payment flow

1. **Challenge start.** App calls the server; server stores the challenge with
   its own `end_at` and returns the challenge ID. If the server cannot be
   reached, decide now whether a challenge may start offline (recommendation:
   no, once money is real).
2. **User taps End Challenge**, sees the amount, taps Continue to Payment.
3. **App asks the server for an order.** Server checks: challenge is ACTIVE,
   enough time remains (at least the order's lifetime, e.g. 15 minutes), no
   captured payment exists. It returns the existing order if one is open,
   otherwise creates one with the provider using the stored amount. Order
   expiry = the earlier of 15 minutes and challenge end.
4. **App opens the provider's checkout** with the order ID.
5. **Checkout returns** success, failure or nothing at all. The app sends
   whatever it received to the server.
6. **Server decides.** It verifies the provider's signature, and independently
   receives the provider's webhook. Either one moves the payment to CAPTURED,
   once. Then it sets the challenge to ENDED_EARLY.
7. **App polls the challenge status** (every few seconds for up to 2 minutes,
   then on every app open). It unlocks only when the server says ENDED_EARLY.
8. **Late capture.** If the capture arrives after `end_at`, the server marks
   REFUND_PENDING and refunds automatically. The app shows "Challenge completed.
   Your payment is being refunded."
9. **Daily reconciliation.** Server compares its payments with the provider's
   settlement report and flags mismatches.

## F. Required API endpoints

| Endpoint | Purpose |
|----------|---------|
| `POST /v1/devices/register` | Issue install ID and token |
| `POST /v1/challenges` | Register a challenge; returns ID and server `end_at` |
| `GET /v1/challenges/{id}` | Authoritative status, including payment state |
| `POST /v1/challenges/{id}/events` | Emergency use, interruption events, completion report |
| `POST /v1/challenges/{id}/payment-order` | Create or return the one open order (idempotent) |
| `POST /v1/payments/{id}/client-result` | App reports what the checkout returned |
| `GET /v1/payments/{id}` | Status for polling |
| `POST /v1/webhooks/{provider}` | Provider callbacks (signature-checked, de-duplicated) |
| `POST /v1/payments/{id}/refund` | Internal/admin only |

All app-facing calls carry the device token; write calls carry an idempotency
key.

## G. Payment state machine

Server (authoritative):

```
CREATED ──checkout opened──▶ PENDING ──webhook/verify──▶ CAPTURED ──▶ challenge ENDED_EARLY
   │                            │                            │
   │                            ├─▶ FAILED ──(new attempt on the same order)──▶ PENDING
   │                            ├─▶ CANCELLED ─(same)
   └────────────expiry──────────┴─▶ EXPIRED
                                                 CAPTURED after end_at ──▶ REFUND_PENDING ──▶ REFUNDED
```

Rules:
- CAPTURED is terminal for charging: no further attempt is ever created.
- Only CAPTURED before `end_at` produces ENDED_EARLY.
- Transitions are applied once; a repeated webhook is ignored.

App (mirror only; the existing eight states map on like this):

| App state | Meaning | Allowed next step |
|-----------|---------|-------------------|
| NOT_STARTED | No order | Request order |
| INITIATED | Order received, checkout opened | Ask server |
| PENDING | Server says in progress | Ask server |
| NETWORK_ERROR / VERIFICATION_FAILED | Could not reach or confirm | Ask server |
| FAILED / CANCELLED | Server confirmed nothing was captured | Ask server, then new attempt |
| SUCCESSFUL | Server says CAPTURED | Unlock |

The change from today is the FAILED / CANCELLED row (B1).

## H. Security risks

**H1. Platform policy (decide first).** Google Play requires its own billing
system for "app functionality or content". India allows an alternative billing
system *alongside* Play billing, with conditions (PCI DSS certification,
reporting each transaction to Google within 24 hours, a service fee reduced by
4%). Options: (a) use Google Play Billing with fixed price points, which fits
the ₹10–₹1,000 chips but not custom amounts; (b) join the India alternative
billing programme; (c) distribute outside the Play Store. I cannot tell you
which applies to "pay to end a challenge"; ask Google or get advice.

**H2. Trusting the phone.** Amount, time and "paid" must not be taken from the
phone (section C).

**H3. Double charge.** B1, plus webhook replays; handled by one order per
challenge and de-duplication.

**H4. Secrets.** Only the provider's public key may be in the app. Secret key
and webhook secret live on the server.

**H5. Tampered app or rooted phone.** Can unlock without paying and can send
false events. Device attestation (Play Integrity) reduces this; it does not
remove it.

**H6. Abuse.** Order-creation spam, replayed requests, stolen device tokens.
Needs rate limits and short-lived tokens.

**H7. Privacy.** The list of blocked apps and payment history are personal
data. A privacy policy, retention rules and a deletion path are needed, and the
Play Store data-safety form must match.

**H8. Regulatory.** A payment gateway account in India needs a registered
business and KYC. A deposit-and-refund model means holding users' money, which
may bring further obligations. Check both before building.

## I. Android-specific risks

1. **Process death during checkout.** UPI hands off to another app; Android may
   kill Commit meanwhile and the result is lost. Covered only if the server
   check on reopen exists (it will).
2. **Blocker versus checkout.** B8.
3. **Force stop during a pending payment.** Nothing runs until the app is
   reopened; the server may already have CAPTURED. The app reconciles on
   reopen; the apps are unblocked anyway while it is stopped.
4. **Clock.** After a reboot the app's time follows the phone clock. Server
   time removes this for money decisions.
5. **Backup and restore.** B4.
6. **Battery managers** may delay background polling. Poll only while the app
   is open; rely on reopen plus the server for the rest.
7. **Play Protect.** Sideloaded builds with Accessibility are blocked on
   install in India. A Play Store release avoids that but brings Google's
   Accessibility declaration review and H1.
8. **Signing key change** forces reinstall (B10).

## J. Recommended implementation order

1. **Decide the platform question (H1) and the model** (pay-to-quit vs deposit).
   Everything after depends on it.
2. **App hardening that needs no backend:** B1, B4, B5, B8, B10.
3. **Backend skeleton:** device registration, challenge registration, server
   time. Still no payments.
4. **App talks to the backend** for challenge start and status; still no
   payments.
5. **Provider in test mode only:** order creation, webhook, verification,
   polling, expiry. No live keys.
6. **Refund and reconciliation** paths, tested in test mode, including "paid
   after the challenge ended".
7. **Real-device test plan for payments** in test mode: app killed mid-payment,
   airplane mode, UPI app blocked, double tap, late payment.
8. **Go live** with small limits (for example a ₹100 cap) and a short pilot.

## Answers to your 20 review points

| # | Topic | Finding |
|---|-------|---------|
| 1 | Challenge state management | Sound. Stored status vs shown state is deliberate. Needs a server copy. |
| 2 | Commitment Amount storage | Integer rupees in a local file. Fine for display; not acceptable as the amount to charge (B3). |
| 3 | Payment state management | Eight states, persisted, tested. Mirror of the server once one exists. |
| 4 | Reference generation | Client-side; must become server-issued (B2). |
| 5 | Duplicate-payment prevention | Good for unknown outcomes; gap after FAILED/CANCELLED (B1). |
| 6 | Retry behaviour | No limit, no back-off, no expiry (B7). |
| 7 | App restart during payment | Handled (INITIATED saved first, reconcile on start). |
| 8 | Network failure | Handled as NETWORK_ERROR, re-check only. No automatic retry when the network returns. |
| 9 | Paid but no response | Handled by reconcile; needs the webhook to be reliable. |
| 10 | Paid after expiry | Recorded, never re-charged, but no refund (B6). |
| 11 | Interruption while pending | Independent; both are recorded. No conflict found. |
| 12 | Completion while pending | Challenge completes on time; payment keeps being re-checked. Falls into point 10 if it then succeeds. |
| 13 | Data integrity and storage | Atomic single-file writes; no migrations, backup on, reset deletes paid records (B4, B5, B11). |
| 14 | Android lifecycle | See section I. |
| 15 | Client-side security | The app can never be trusted for amount, time or paid status. |
| 16 | Must move to backend | Section C. |
| 17 | Never store locally | Card number, CVV, expiry, UPI PIN, UPI ID beyond a masked form, bank login, OTPs, provider secret key, webhook secret, full provider payloads. |
| 18 | Backend must store | Section D. |
| 19 | Verification | Section E steps 5–7: signature check and webhook, either sufficient, applied once. |
| 20 | Refunds and reconciliation | Section E steps 8–9; none exists today. |

## Sources

- Google Play payments policy: https://support.google.com/googleplay/android-developer/answer/10281818
- Google Play billing changes for India: https://support.google.com/googleplay/android-developer/answer/13306652
- Razorpay integration best practices: https://razorpay.com/docs/payments/payment-gateway/web-integration/standard/best-practices/
- Android `<application>` manifest element (backup attributes): https://developer.android.com/guide/topics/manifest/application-element
