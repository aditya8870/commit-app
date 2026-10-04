import 'dart:math';

import 'commitment.dart';
import 'payment.dart';

/// Who is using the app, as far as the server is concerned.
class Identity {
  const Identity({
    required this.userId,
    required this.deviceId,
    required this.isAuthenticated,
  });

  /// Owner of challenges and payments. Decided by the server.
  final String userId;

  /// This install of the app.
  final String deviceId;

  /// False for the local stand-in: nobody has actually signed in.
  final bool isAuthenticated;
}

/// What the app asks for when a challenge is created. These are requests; the
/// answer ([ChallengeTerms]) is what counts.
class ChallengeRequest {
  const ChallengeRequest({
    required this.apps,
    required this.durationMinutes,
    required this.amountRupees,
    required this.emergencyLimit,
    required this.emergencyMinutes,
    required this.consent,
  });
  final List<AppRef> apps;
  final int durationMinutes;
  final int amountRupees;
  final int emergencyLimit;
  final int emergencyMinutes;

  /// Proof that the user accepted the payment condition before starting.
  final ConsentRecord consent;

  Map<String, Object?> toJson() => {
    'packageNames': [for (final a in apps) a.packageName],
    'appNames': [for (final a in apps) a.appName],
    'durationMinutes': durationMinutes,
    'amountRupees': amountRupees,
    'emergencyLimit': emergencyLimit,
    'emergencyMinutes': emergencyMinutes,
    'consent': consent.toJson(),
  };

  /// Null if the saved request is not usable.
  static ChallengeRequest? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final pkgs = raw['packageNames'], names = raw['appNames'];
    final consent = ConsentRecord.tryParse(raw['consent']);
    if (pkgs is! List ||
        names is! List ||
        pkgs.isEmpty ||
        pkgs.length != names.length ||
        consent == null ||
        raw['durationMinutes'] is! int ||
        raw['amountRupees'] is! int ||
        raw['emergencyLimit'] is! int ||
        raw['emergencyMinutes'] is! int) {
      return null;
    }
    return ChallengeRequest(
      apps: [
        for (var i = 0; i < pkgs.length; i++)
          AppRef('${pkgs[i]}', '${names[i]}'),
      ],
      durationMinutes: raw['durationMinutes'] as int,
      amountRupees: raw['amountRupees'] as int,
      emergencyLimit: raw['emergencyLimit'] as int,
      emergencyMinutes: raw['emergencyMinutes'] as int,
      consent: consent,
    );
  }
}

/// A registration that was sent (or was about to be sent) to the backend and
/// whose result the phone has not stored yet. Saved BEFORE the request, so a
/// crash or lost connection cannot leave the server with a challenge the
/// phone does not know about.
class PendingRegistration {
  const PendingRegistration({
    required this.idempotencyKey,
    required this.request,
    required this.createdAt,
  });
  final String idempotencyKey;
  final ChallengeRequest request;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'idempotencyKey': idempotencyKey,
    'request': request.toJson(),
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  static PendingRegistration? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['idempotencyKey'], at = raw['createdAt'];
    final request = ChallengeRequest.tryParse(raw['request']);
    if (key is! String || key.isEmpty || at is! int || request == null) {
      return null;
    }
    return PendingRegistration(
      idempotencyKey: key,
      request: request,
      createdAt: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

/// Everything besides the terms that is needed to rebuild a challenge on a
/// phone that has no copy of it (reinstall, new device, cleared data).
class ChallengeDetails {
  const ChallengeDetails({
    required this.apps,
    required this.durationMinutes,
    required this.emergencyLimit,
    required this.emergencyMinutes,
    required this.emergencyUsed,
    this.consent,
  });
  final List<AppRef> apps;
  final int durationMinutes;
  final int emergencyLimit;
  final int emergencyMinutes;
  final int emergencyUsed;
  final ConsentRecord? consent;
}

/// Something that happened to a challenge on the phone, reported to the
/// backend for its record. Reporting never charges and never ends a challenge.
class ChallengeEvent {
  const ChallengeEvent({
    required this.eventId,
    required this.challengeId,
    required this.type,
    required this.at,
  });

  static const emergencyUsed = 'emergencyUsed';
  static const completedOnDevice = 'completedOnDevice';
  static const clockJump = 'clockJump';
  static const restoredOnDevice = 'restoredOnDevice';

  /// Unique per event, so the server can ignore a repeat.
  final String eventId;
  final String challengeId;

  /// One of the constants above or an [IntegrityEvent] type.
  final String type;
  final DateTime at;

  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'challengeId': challengeId,
    'type': type,
    'at': at.millisecondsSinceEpoch,
  };

  static ChallengeEvent? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['eventId'], ch = raw['challengeId'];
    final type = raw['type'], at = raw['at'];
    if (id is! String || ch is! String || type is! String || at is! int) {
      return null;
    }
    return ChallengeEvent(
      eventId: id,
      challengeId: ch,
      type: type,
      at: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

/// The terms of a challenge as fixed by the backend. The phone stores a copy
/// for display and for blocking; it never overrides them.
class ChallengeTerms {
  const ChallengeTerms({
    required this.challengeId,
    required this.ownerUserId,
    required this.startTime,
    required this.endTime,
    required this.amountRupees,
    required this.authoritative,
  });
  final String challengeId;
  final String ownerUserId;
  final DateTime startTime;
  final DateTime endTime;
  final int amountRupees;

  /// True when a real server issued these terms; false for the stand-in.
  final bool authoritative;
}

enum ServerChallengeStatus { active, completed, endedEarly, cancelled }

/// The backend's current view of a challenge, used to reconcile the phone.
class ServerChallenge {
  const ServerChallenge({
    required this.terms,
    required this.status,
    this.payment,
    this.actualEndTime,
    this.details,
  });

  /// Present when the server returns the full challenge (for restoring it).
  final ChallengeDetails? details;
  final ChallengeTerms terms;
  final ServerChallengeStatus status;
  final PaymentOutcome? payment;
  final DateTime? actualEndTime;
}

/// The backend's answer to "may a checkout be opened for this challenge now?".
class PaymentAttemptDecision {
  /// A checkout may be opened, for exactly this reference and amount.
  const PaymentAttemptDecision.allowed({
    required String this.reference,
    required int this.amountRupees,
    required this.attempt,
    this.expiresAt,
  }) : allowed = true,
       current = null;

  /// No checkout. [current] is the authoritative state of the payment
  /// (for example already paid, still pending, or too late).
  const PaymentAttemptDecision.denied(PaymentOutcome this.current)
    : allowed = false,
      reference = null,
      amountRupees = null,
      attempt = 0,
      expiresAt = null;

  final bool allowed;
  final String? reference;
  final int? amountRupees;

  /// 1 for the first checkout of a challenge, 2 for the second, and so on.
  final int attempt;
  final DateTime? expiresAt;
  final PaymentOutcome? current;
}

/// Everything the phone is NOT allowed to decide for itself.
///
/// A production implementation calls the server. Until one exists the app
/// uses `StandInBackend`, which answers locally and says so through
/// [isConnected] and [ChallengeTerms.authoritative].
abstract class CommitBackend {
  /// False while no real server is connected.
  bool get isConnected;

  /// Establishes who the user and device are. [installId] is this install's
  /// stable identifier; the server maps it to an account.
  Future<Identity> signIn({required String installId});

  /// Registers a challenge and returns its fixed terms: ID, owner, start and
  /// end time (server clock) and amount. Repeating a call with the same
  /// [idempotencyKey] must return the same challenge.
  Future<ChallengeTerms> registerChallenge(
    ChallengeRequest request, {
    required String idempotencyKey,
  });

  /// What became of a registration sent earlier with [idempotencyKey]: the
  /// challenge it created, or null if the server never created one. Unlike
  /// [registerChallenge] this never creates anything.
  Future<ChallengeTerms?> registrationResult(String idempotencyKey);

  /// The signed-in user's running challenge with everything needed to rebuild
  /// it, or null if they have none. Used after reinstall, device change or
  /// cleared data.
  Future<ServerChallenge?> currentChallenge();

  /// Stores events for the server's record. Must ignore an eventId it has
  /// already seen.
  Future<void> reportEvents(List<ChallengeEvent> events);

  /// The server's current view, or null if it does not know the challenge.
  Future<ServerChallenge?> fetchChallenge(String challengeId);

  /// Must be called before EVERY checkout, first attempt or retry. The server
  /// checks the existing payment first and only then allows a new attempt.
  /// Repeating a call with the same [idempotencyKey] returns the same answer.
  Future<PaymentAttemptDecision> authorizePaymentAttempt(
    String challengeId, {
    required String idempotencyKey,
  });

  /// The authoritative status of the payment for a challenge. This, not the
  /// checkout's own report, decides whether a challenge has been paid for.
  Future<PaymentOutcome> paymentStatus(String challengeId);
}

/// Random 128-bit keys that make a repeated request recognisable as the same
/// request.
class IdempotencyKey {
  const IdempotencyKey._();

  static final Random _random = Random.secure();

  static String generate() {
    final b = StringBuffer();
    for (var i = 0; i < 16; i++) {
      b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }
}
