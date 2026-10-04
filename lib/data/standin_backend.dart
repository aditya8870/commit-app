import 'dart:math';

import '../core/backend.dart';
import '../core/clock.dart';
import '../core/commitment.dart';
import '../core/payment.dart';

/// ╔══════════════════════════════════════════════════════════════════════╗
/// ║ DEVELOPMENT STAND-IN — NOT A SERVER, NOT AUTHORITATIVE.              ║
/// ║                                                                      ║
/// ║ It answers the backend's questions on the phone so the app works     ║
/// ║ before a real backend exists. It issues IDs, times and references    ║
/// ║ locally, marks them as non-authoritative, and can never make a       ║
/// ║ payment succeed: payment truth still comes only from                 ║
/// ║ PaymentService.verify. Replace it with a class that calls the real   ║
/// ║ server; nothing else in the app needs to change.                     ║
/// ╚══════════════════════════════════════════════════════════════════════╝
class StandInBackend implements CommitBackend {
  StandInBackend({required this.clock, required this.payments});

  final Clock clock;
  final PaymentService payments;

  /// Lets the stand-in look up the phone's own copy of a challenge, which a
  /// real server would have in its database. Set by the controller.
  Commitment? Function(String challengeId)? localLookup;

  final Map<String, ChallengeTerms> _registrations = {};
  final Map<String, PaymentAttemptDecision> _decisions = {};

  @override
  bool get isConnected => false;

  static String referenceFor(String challengeId) => 'commit-$challengeId';

  @override
  Future<Identity> signIn({required String installId}) async => Identity(
    userId: 'local-$installId',
    deviceId: installId,
    isAuthenticated: false,
  );

  @override
  Future<ChallengeTerms> registerChallenge(
    ChallengeRequest request, {
    required String idempotencyKey,
  }) async {
    final again = _registrations[idempotencyKey];
    if (again != null) return again;
    final now = clock.now();
    final terms = ChallengeTerms(
      challengeId: '${now.microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}',
      ownerUserId: 'local',
      startTime: now,
      endTime: now.add(Duration(minutes: request.durationMinutes)),
      amountRupees: request.amountRupees,
      authoritative: false,
    );
    _registrations[idempotencyKey] = terms;
    return terms;
  }

  @override
  Future<ServerChallenge?> fetchChallenge(String challengeId) async => null;

  // Nothing exists outside the phone, so there is nothing to find, restore
  // or report to.
  @override
  Future<ChallengeTerms?> registrationResult(String idempotencyKey) async =>
      _registrations[idempotencyKey];

  @override
  Future<ServerChallenge?> currentChallenge() async => null;

  @override
  Future<void> reportEvents(List<ChallengeEvent> events) async {}

  @override
  Future<PaymentAttemptDecision> authorizePaymentAttempt(
    String challengeId, {
    required String idempotencyKey,
  }) async {
    final again = _decisions[idempotencyKey];
    if (again != null) return again;

    // Same rule a real server follows: look at the existing payment first.
    final current = await paymentStatus(challengeId);
    final PaymentAttemptDecision decision;
    final c = localLookup?.call(challengeId);
    if (current.status == PaymentStatus.successful ||
        current.status.mustVerifyBeforeRetry) {
      decision = PaymentAttemptDecision.denied(current);
    } else if (c == null || !c.isLive) {
      decision = const PaymentAttemptDecision.denied(
        PaymentOutcome(
          PaymentStatus.failed,
          message: 'This challenge is no longer active.',
        ),
      );
    } else {
      decision = PaymentAttemptDecision.allowed(
        reference: referenceFor(challengeId),
        amountRupees: c.commitmentAmount,
        attempt: (c.payment?.attempt ?? 0) + 1,
        expiresAt: c.endTime,
      );
    }
    _decisions[idempotencyKey] = decision;
    return decision;
  }

  @override
  Future<PaymentOutcome> paymentStatus(String challengeId) async {
    try {
      return await payments.verify(referenceFor(challengeId));
    } catch (_) {
      return const PaymentOutcome(PaymentStatus.networkError);
    }
  }
}
