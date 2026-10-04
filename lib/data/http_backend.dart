import '../core/backend.dart';
import '../core/commitment.dart';
import '../core/installation.dart';
import '../core/payment.dart';
import 'api_client.dart';
import 'installation_service.dart';

/// A finished challenge as the server has it (for history).
class ServerChallengeRecord {
  const ServerChallengeRecord(this.challenge, this.emergencyUsed);
  final ServerChallenge challenge;
  final int emergencyUsed;
}

/// One page of finished challenges.
class ChallengeHistoryPage {
  const ChallengeHistoryPage(this.items, this.nextBefore);
  final List<ServerChallenge> items;

  /// Pass to the next call to get older challenges; null when there are none.
  final String? nextBefore;
}

/// The real backend: every answer comes from the Commit server.
///
/// The rest of the app only sees [CommitBackend]; nothing about addresses,
/// JSON or headers leaves this file.
///
/// Rules it keeps:
/// - It never decides a start time, an end time, a completion or a payment.
/// - It throws when the server cannot be reached, so the app keeps its last
///   known state instead of guessing.
/// - Every changing request carries a key or ID that makes a repeat harmless.
class HttpCommitBackend implements CommitBackend {
  HttpCommitBackend({required this.api, required this.installation});

  final ApiClient api;
  final InstallationService installation;

  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static final _hex32 = RegExp(r'^[0-9a-f]{32}$');

  // Names of the phone's observations in the API.
  static const _eventTypes = {
    IntegrityEvent.forceStopped: 'force_stopped',
    IntegrityEvent.accessibilityOff: 'accessibility_off',
    IntegrityEvent.protectionLost: 'protection_lost',
    IntegrityEvent.protectionRestored: 'protection_restored',
    IntegrityEvent.tamperProtectionOff: 'tamper_protection_off',
    ChallengeEvent.clockJump: 'clock_jump',
    ChallengeEvent.restoredOnDevice: 'restored_on_device',
  };

  @override
  bool get isConnected => true;

  /// Uses the network only if this phone is not registered yet.
  Future<InstallationIdentity> _me() async {
    final stored = await installation.loadStored();
    if (stored != null) return stored;
    await installation.ensureRegistered();
    final me = installation.identity;
    if (me == null) {
      throw const ApiException(ApiException.network, retryable: true);
    }
    return me;
  }

  /// Sends a signed request. If the server no longer accepts the credential,
  /// the installation is recovered in the background and the call fails this
  /// once, like any other temporary failure.
  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    String? idempotencyKey,
  }) async {
    final me = await _me();
    try {
      return await api.send(
        method,
        path,
        body: body,
        auth: me,
        query: query,
        idempotencyKey: idempotencyKey,
      );
    } on ApiException catch (e) {
      if (e.code == ApiException.unauthenticated) await installation.verify();
      rethrow;
    }
  }

  @override
  Future<Identity> signIn({required String installId}) async {
    // Must not wait for the network: the app is starting.
    final me = await installation.loadStored();
    if (me == null) {
      throw const ApiException(ApiException.network, retryable: true);
    }
    return Identity(userId: me.id, deviceId: me.id, isAuthenticated: true);
  }

  @override
  Future<ChallengeTerms> registerChallenge(
    ChallengeRequest request, {
    required String idempotencyKey,
  }) async {
    final answer = await _send(
      'POST',
      '/v1/challenges',
      idempotencyKey: idempotencyKey,
      // No start time, end time or status: the server decides those.
      body: {
        'apps': [
          for (final a in request.apps)
            {'packageName': a.packageName, 'appName': a.appName},
        ],
        'durationMinutes': request.durationMinutes,
        'amountRupees': request.amountRupees,
        'emergencyLimit': request.emergencyLimit,
        'emergencyMinutes': request.emergencyMinutes,
        'consentVersion': request.consent.version,
        'consentAccepted': true,
      },
    );
    return _parse(answer['challenge']).terms;
  }

  @override
  Future<ChallengeTerms?> registrationResult(String idempotencyKey) async {
    try {
      final answer = await _send(
        'GET',
        '/v1/challenges/registrations/$idempotencyKey',
      );
      return _parse(answer['challenge']).terms;
    } on ApiException catch (e) {
      if (e.code == ApiException.notFound) return null; // nothing was created
      rethrow;
    }
  }

  @override
  Future<ServerChallenge?> currentChallenge() async {
    final answer = await _send('GET', '/v1/challenges/active');
    final c = answer['challenge'];
    return c == null ? null : _parse(c);
  }

  @override
  Future<ServerChallenge?> fetchChallenge(String challengeId) async {
    // A challenge made before the server existed has a local-only ID.
    if (!_uuid.hasMatch(challengeId)) return null;
    try {
      final answer = await _send('GET', '/v1/challenges/$challengeId');
      return _parse(answer['challenge']);
    } on ApiException catch (e) {
      if (e.code == ApiException.notFound) return null;
      rethrow;
    }
  }

  /// Finished challenges, newest first.
  Future<ChallengeHistoryPage> fetchHistory({
    String? before,
    int limit = 20,
  }) async {
    final answer = await _send(
      'GET',
      '/v1/challenges/history',
      query: {'limit': '$limit', 'before': ?before},
    );
    final items = answer['items'];
    if (items is! List) {
      throw const ApiException(ApiException.malformedResponse);
    }
    final next = answer['nextBefore'];
    return ChallengeHistoryPage([
      for (final i in items) _parse(i),
    ], next is String ? next : null);
  }

  /// Sends what the phone observed. Throws if anything could not be
  /// delivered, so the caller keeps everything queued; re-sending is safe
  /// because every item carries its own ID.
  @override
  Future<void> reportEvents(List<ChallengeEvent> events) async {
    final observations = <String, List<Map<String, Object?>>>{};
    final minutes = <String, int>{};

    for (final e in events) {
      if (!_uuid.hasMatch(e.challengeId)) continue; // local-only challenge
      final id = _asUuid(e.eventId);
      if (id == null) continue;
      final at = e.at.toUtc().toIso8601String();
      final base = '/v1/challenges/${e.challengeId}';

      if (e.type == ChallengeEvent.emergencyUsed) {
        final length = minutes[e.challengeId] ??=
            (await fetchChallenge(e.challengeId))?.details?.emergencyMinutes ??
            0;
        if (length == 0) continue; // the server does not know this challenge
        await _deliver(
          () => _send(
            'POST',
            '$base/emergency',
            body: {'useId': id, 'startedAt': at, 'minutes': length},
          ),
        );
      } else if (e.type == ChallengeEvent.completedOnDevice) {
        // A request, not a decision: the server completes it only if its own
        // clock agrees.
        await _deliver(() => _send('POST', '$base/complete', body: const {}));
      } else {
        final type = _eventTypes[e.type];
        if (type == null) continue;
        observations.putIfAbsent(e.challengeId, () => []).add({
          'id': id,
          'type': type,
          'deviceTime': at,
        });
      }
    }

    for (final entry in observations.entries) {
      for (var i = 0; i < entry.value.length; i += 100) {
        final batch = entry.value.skip(i).take(100).toList();
        await _deliver(
          () => _send(
            'POST',
            '/v1/challenges/${entry.key}/events',
            body: {'events': batch},
          ),
        );
      }
    }
  }

  /// An answer that says "the server has it" or "the server will never take
  /// it" counts as delivered. Only a temporary failure is passed on.
  Future<void> _deliver(Future<Object?> Function() request) async {
    try {
      await request();
    } on ApiException catch (e) {
      const settled = {
        ApiException.tooEarly,
        ApiException.challengeNotActive,
        ApiException.emergencyLimitExceeded,
        ApiException.notFound,
        ApiException.validationFailed,
      };
      if (!settled.contains(e.code)) rethrow;
    }
  }

  /// Ending early needs a verified payment. None is available, so the server
  /// refuses and the challenge stays active. Nothing here can report success.
  @override
  Future<PaymentAttemptDecision> authorizePaymentAttempt(
    String challengeId, {
    required String idempotencyKey,
  }) async {
    if (!_uuid.hasMatch(challengeId)) {
      return const PaymentAttemptDecision.denied(
        PaymentOutcome(PaymentStatus.notStarted),
      );
    }
    try {
      await _send(
        'POST',
        '/v1/challenges/$challengeId/end-early',
        idempotencyKey: idempotencyKey,
        body: const {},
      );
    } on ApiException catch (e) {
      const refusals = {
        ApiException.paymentsUnavailable,
        ApiException.challengeNotActive,
        ApiException.notFound,
        'TOO_CLOSE_TO_END',
      };
      if (!refusals.contains(e.code)) rethrow;
      return PaymentAttemptDecision.denied(
        PaymentOutcome(
          PaymentStatus.notStarted,
          message: e.code == ApiException.paymentsUnavailable
              ? 'Payments are not available yet. Your challenge is still active.'
              : 'This challenge cannot be ended early right now.',
        ),
      );
    }
    // The server accepted without a payment system: never treat that as paid.
    return const PaymentAttemptDecision.denied(
      PaymentOutcome(PaymentStatus.notStarted),
    );
  }

  @override
  Future<PaymentOutcome> paymentStatus(String challengeId) async {
    final c = await fetchChallenge(challengeId);
    // Only what the server states. There is no payment system yet, so the
    // only status it can report is "not started".
    return c?.payment ?? const PaymentOutcome(PaymentStatus.notStarted);
  }

  // ---------------------------------------------------------------- parsing

  static String? _asUuid(String id) {
    if (_uuid.hasMatch(id)) return id;
    if (!_hex32.hasMatch(id)) return null;
    return '${id.substring(0, 8)}-${id.substring(8, 12)}-'
        '${id.substring(12, 16)}-${id.substring(16, 20)}-${id.substring(20)}';
  }

  static DateTime _time(Object? v) {
    if (v is! String) throw const ApiException(ApiException.malformedResponse);
    final t = DateTime.tryParse(v);
    if (t == null) throw const ApiException(ApiException.malformedResponse);
    return t.toLocal();
  }

  static int _int(Object? v, int min, int max) {
    if (v is! int || v < min || v > max) {
      throw const ApiException(ApiException.malformedResponse);
    }
    return v;
  }

  /// Turns the server's JSON into typed values, refusing anything malformed
  /// rather than storing it.
  static ServerChallenge _parse(Object? raw) {
    if (raw is! Map) throw const ApiException(ApiException.malformedResponse);
    final j = raw.cast<String, Object?>();
    final id = j['id'];
    if (id is! String || !_uuid.hasMatch(id)) {
      throw const ApiException(ApiException.malformedResponse);
    }
    final status = switch (j['status']) {
      'active' => ServerChallengeStatus.active,
      'completed' => ServerChallengeStatus.completed,
      'ended_early' => ServerChallengeStatus.endedEarly,
      'cancelled' => ServerChallengeStatus.cancelled,
      _ => throw const ApiException(ApiException.malformedResponse),
    };
    final start = _time(j['startTime']), end = _time(j['endTime']);
    if (!end.isAfter(start)) {
      throw const ApiException(ApiException.malformedResponse);
    }
    final apps = j['apps'];
    if (apps is! List || apps.length > 50) {
      throw const ApiException(ApiException.malformedResponse);
    }
    final version = j['consentVersion'];
    // 0 = no financial commitment.
    final amount = _int(j['amountRupees'], 0, 10000);
    if (amount != 0 && amount < 100) {
      throw const ApiException(ApiException.malformedResponse);
    }
    return ServerChallenge(
      terms: ChallengeTerms(
        challengeId: id,
        ownerUserId: '',
        startTime: start,
        endTime: end,
        amountRupees: amount,
        authoritative: true,
      ),
      status: status,
      actualEndTime: j['actualEndTime'] == null
          ? null
          : _time(j['actualEndTime']),
      // No payment system exists: the server reports "not_started", which the
      // app represents as "no payment record".
      payment: null,
      details: ChallengeDetails(
        apps: [
          for (final a in apps)
            if (a is Map &&
                a['packageName'] is String &&
                a['appName'] is String)
              AppRef(a['packageName'] as String, a['appName'] as String),
        ],
        durationMinutes: _int(j['durationMinutes'], 1, 43200),
        emergencyLimit: _int(j['emergencyLimit'], 0, 3),
        emergencyMinutes: _int(j['emergencyMinutes'], 1, 60),
        emergencyUsed: _int(j['emergencyUsed'], 0, 1000),
        consent: version is String && j['consentAcceptedAt'] != null
            ? ConsentRecord(
                version: version,
                acceptedAt: _time(j['consentAcceptedAt']),
                amountRupees: amount,
              )
            : null,
      ),
    );
  }
}
