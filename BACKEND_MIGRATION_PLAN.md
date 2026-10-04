# Commit 2.3.0 — migration plan to a real backend and payment provider

2.3.0 contains no backend, no payment provider and no payment SDK. It contains
the two seams they will plug into and the rules around them.

## The two seams

| Seam | File | Shipped implementation | Goes live as |
|------|------|------------------------|--------------|
| `CommitBackend` | `lib/core/backend.dart` | `StandInBackend` (local, marked non-authoritative) | A class that calls your server |
| `PaymentService` | `lib/core/payment.dart` | `UnconfiguredPaymentService` (never succeeds) | A class that opens the provider's checkout |

Both are passed to `CommitController` in `lib/main.dart`. Nothing else in the
app constructs them.

## What the server must answer

| Call | Server decides |
|------|----------------|
| `signIn(installId)` | User ID, device ID, whether authenticated |
| `registerChallenge(request, idempotencyKey)` | Challenge ID, owner, start time, **end time**, **amount** |
| `fetchChallenge(id)` | Current terms and status; payment state if any |
| `authorizePaymentAttempt(id, idempotencyKey)` | Whether a checkout may open; **reference**, **amount**, attempt number, expiry |
| `paymentStatus(id)` | The final payment status |

Same idempotency key in, same answer out.

## What already behaves as it will in production

- A challenge is created from the terms the backend returns, not from the
  phone's own values.
- No checkout opens without `authorizePaymentAttempt` saying yes, for the
  first attempt and for every retry.
- An unknown outcome only triggers a status check.
- After any checkout the app asks the backend and stores the backend's answer.
- On start and on resume the app re-reads the challenge from the backend and
  adopts its end time, amount and payment state.
- Local "reset" keeps paid and unresolved records; Android backup is off.

## Steps, in order

1. **Backend skeleton.** Sign-in, the five calls above, a database with
   `users`, `devices`, `challenges`, `payments`, `payment_events`,
   `challenge_events`. No provider yet: `authorizePaymentAttempt` can refuse
   everything.
2. **`HttpCommitBackend`.** Implements `CommitBackend` over HTTPS.
   `isConnected` returns true. Add the internet permission and update the
   in-app Privacy text, which currently says the app does not use the internet.
3. **Decide what happens offline.** With a connected backend, starting a
   challenge without the server already fails cleanly ("Nothing was
   started"). Blocking an existing challenge continues offline.
4. **Existing local challenges.** Records created by the stand-in have
   `serverIssued: false`. On first run against a real server, either let them
   finish locally (simplest; they have no money attached yet) or upload them
   for registration. Recommended: let them finish.
5. **Provider in test mode.** Implement `PaymentService.pay` to open the
   provider's checkout with the reference from `authorizePaymentAttempt`.
   `verify` is then only used by the stand-in and can throw.
6. **Server side of payments.** Order creation inside
   `authorizePaymentAttempt`; provider signature check; webhook or server
   notification handler; de-duplication by provider event ID.
7. **Refunds and reconciliation.** Automatic refund for a capture after the
   challenge's end; scheduled job comparing open payments with the provider.
8. **Send events.** `emergency used`, interruptions and completion reports to
   `POST /challenges/{id}/events` (not wired yet; the data is already recorded
   on the challenge).
9. **Device re-test** of the payment paths, including the checkout window
   (payment apps the user blocked must open during a checkout and be blocked
   again when it closes).
10. **Release key** (see `RELEASE_SIGNING.md`) before anyone outside testing
    installs it.

## Things this plan does not decide

- Which provider (the Google Play policy question is still open).
- Whether custom amounts stay (Google Play Billing needs fixed price tiers).
- Sign-in method (Google account or phone number).
- Hosting.
