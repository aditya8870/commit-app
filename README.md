# Commit

"Decide before temptation." Android digital-detox and commitment app built with Flutter + Kotlin.

Create a challenge in five steps: select apps → choose duration (2 minutes to 30 days, or custom) → emergency access (0-3 uses of 2-30 minutes) → Commitment Amount (₹10-₹10,000) → review.

## Commitment Amount and payments

The Commitment Amount is only due if the user chooses to end a challenge early,
and only after they confirm twice (End Challenge? → Continue to Payment → Pay).
Completing a challenge, or using emergency access, costs nothing.

**No payment provider and no backend are connected.** Two seams exist:

- `CommitBackend` (`lib/core/backend.dart`) decides the challenge ID, owner,
  start and end time, amount, payment reference and final payment status. The
  shipped `StandInBackend` answers locally and marks everything it issues as
  non-authoritative.
- `PaymentService` (`lib/core/payment.dart`) opens the provider's checkout.
  The shipped `UnconfiguredPaymentService` never reports success.

Rules the controller enforces (`endChallengeWithPayment`):

- no checkout opens unless the backend authorises that attempt, first or retry;
- an unknown outcome is only re-checked, never re-charged;
- the attempt and its idempotency key are saved before anything leaves the phone;
- after any checkout, the backend's status is what gets stored;
- the challenge ends only on a success the backend confirms;
- no card, CVV, UPI PIN or banking details are ever stored.

See `BACKEND_MIGRATION_PLAN.md` and `RELEASE_SIGNING.md`.

## Build

    flutter pub get
    flutter analyze
    flutter test
    flutter build apk --release      # build/app/outputs/flutter-apk/app-release.apk

## Layout

    lib/core/        Commitment model, CommitmentEngine (pure time rules), Clock
    lib/data/        CommitController: the single source of truth in Dart
    lib/platform/    PlatformBridge: MethodChannel "com.commit.app/native"
    lib/ui/          Theme, widgets, screens
    android/.../kotlin/com/commit/app/
        Blocker.kt                     Lock overlay + go home + open Commit
        CommitAccessibilityService.kt  Primary detector (event-driven)
        BlockerService.kt              Backup detector (usage log) + notification
        NativeStore.kt      SharedPreferences storage, LockState, TrustedClock
        AppListProvider.kt  Launchable apps minus critical system apps
        MainActivity.kt     Method channel handlers

## How state works

Flutter writes one JSON document to SharedPreferences. The Kotlin service only
reads it. Both sides derive "is the app blocked right now?" from the same four
timestamps (start, end, emergency start, emergency end) and the trusted time,
so there is no countdown that can be reset.
