// Phase 5: the challenge API client and offline synchronisation.
//
// The real controller and the real HttpCommitBackend run against a stand-in
// server that follows the Phase 5 API contract and has its own clock.
import 'dart:convert';

import 'package:app/core/backend.dart';
import 'package:app/core/commitment.dart';
import 'package:app/core/commitment_engine.dart';
import 'package:app/core/installation.dart';
import 'package:app/core/payment.dart';
import 'package:app/data/api_client.dart';
import 'package:app/data/commit_controller.dart';
import 'package:app/data/http_backend.dart';
import 'package:app/data/installation_service.dart';
import 'package:app/data/server_time.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'installation_test.dart' show FakePlatform, FakeServer;

const _base = 'https://api.example.test/functions/v1/api';

/// Follows the Phase 5 contract. Its clock ([now]) is the only clock that
/// decides start, end and completion, exactly like the real server.
class ChallengeServer extends FakeServer {
  ChallengeServer(this.now);
  DateTime now;
  final List<Map<String, Object?>> challenges = [];
  final List<Map<String, Object?>> emergencyUses = [];
  final List<Map<String, Object?>> events = [];
  int _n = 1;

  /// Create the challenge but lose the answer (connection dropped).
  bool dropCreateAnswer = false;

  ApiRawResponse _ok(int status, Map<String, Object?> body) => ApiRawResponse(
    status,
    jsonEncode({
      ...body,
      'serverTime': now.toUtc().toIso8601String(),
      'epochMs': now.millisecondsSinceEpoch,
    }),
    const {},
  );
  ApiRawResponse _err(
    int status,
    String code, [
    Map<String, Object?> extra = const {},
  ]) =>
      _ok(status, {'code': code, 'message': 'x', 'retryable': false, ...extra});

  Map<String, Object?> _view(Map<String, Object?> c) => {
    'id': c['id'],
    'status': c['status'],
    'startTime': (c['start'] as DateTime).toUtc().toIso8601String(),
    'endTime': (c['end'] as DateTime).toUtc().toIso8601String(),
    'actualEndTime': c['status'] == 'completed'
        ? (c['end'] as DateTime).toUtc().toIso8601String()
        : null,
    'durationMinutes': c['duration'],
    'amountRupees': c['amount'],
    'emergencyLimit': c['limit'],
    'emergencyMinutes': c['minutes'],
    'emergencyUsed': emergencyUses
        .where((u) => u['challenge'] == c['id'])
        .length,
    'interruptionCount': 0,
    'consentVersion': c['consentVersion'],
    'consentAcceptedAt': (c['start'] as DateTime).toUtc().toIso8601String(),
    'createdAt': (c['start'] as DateTime).toUtc().toIso8601String(),
    'apps': c['apps'],
    'payment': {'status': 'not_started', 'available': false},
  };

  void _completeDue() {
    for (final c in challenges) {
      if (c['status'] == 'active' && !(c['end'] as DateTime).isAfter(now)) {
        c['status'] = 'completed';
      }
    }
  }

  @override
  Future<ApiRawResponse> send(ApiRequest r) async {
    final path = r.uri.path.replaceFirst('/functions/v1/api', '');
    if (!path.startsWith('/v1/challenges')) return super.send(r);
    requests.add(r);
    if (offline) throw Exception('no route to host');
    final forced = intercept?.call(r);
    if (forced != null) return forced;

    final auth = r.headers['authorization'] ?? '';
    final who = installations.where(
      (i) =>
          'Bearer ${i['credential']}' == auth &&
          i['id'] == r.headers['x-installation-id'],
    );
    if (who.isEmpty) return _err(401, 'UNAUTHENTICATED');
    final me = who.first['id'];
    _completeDue();
    final mine = challenges.where((c) => c['owner'] == me).toList();
    final body = r.body == null
        ? <String, Object?>{}
        : (jsonDecode(r.body!) as Map).cast<String, Object?>();
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    // parts: v1, challenges, [x], [y]

    if (parts.length == 2 && r.method == 'POST') {
      final key = r.headers['idempotency-key'];
      if (key == null) return _err(400, 'IDEMPOTENCY_KEY_REQUIRED');
      for (final f in ['startTime', 'endTime', 'status', 'installationId']) {
        if (body.containsKey(f)) return _err(422, 'VALIDATION_FAILED');
      }
      final same = mine.where((c) => c['key'] == key);
      if (same.isNotEmpty) return _ok(200, {'challenge': _view(same.first)});
      if (mine.any((c) => c['status'] == 'active')) {
        return _err(409, 'ACTIVE_CHALLENGE_EXISTS');
      }
      final amount = body['amountRupees'], minutes = body['durationMinutes'];
      if (amount is! int ||
          (amount != 0 && amount < 100) ||
          amount < 0 ||
          amount > 10000 ||
          minutes is! int) {
        return _err(422, 'VALIDATION_FAILED');
      }
      final c = <String, Object?>{
        'id': '10000000-0000-4000-8000-${(_n++).toString().padLeft(12, '0')}',
        'owner': me,
        'key': key,
        'status': 'active',
        'start': now,
        'end': now.add(Duration(minutes: minutes)),
        'duration': minutes,
        'amount': amount,
        'limit': body['emergencyLimit'],
        'minutes': body['emergencyMinutes'],
        'consentVersion': body['consentVersion'],
        'apps': body['apps'],
      };
      challenges.add(c);
      if (dropCreateAnswer) throw Exception('connection reset');
      return _ok(201, {'challenge': _view(c)});
    }
    if (parts.length == 3 && parts[2] == 'active') {
      final a = mine.where((c) => c['status'] == 'active');
      return _ok(200, {'challenge': a.isEmpty ? null : _view(a.first)});
    }
    if (parts.length == 3 && parts[2] == 'history') {
      final limit = int.parse(r.uri.queryParameters['limit'] ?? '20');
      final before = r.uri.queryParameters['before'];
      final done =
          mine
              .where((c) => c['status'] != 'active')
              .where(
                (c) =>
                    before == null ||
                    (c['start'] as DateTime).isBefore(DateTime.parse(before)),
              )
              .toList()
            ..sort(
              (a, b) =>
                  (b['start'] as DateTime).compareTo(a['start'] as DateTime),
            );
      final page = done.take(limit).toList();
      return _ok(200, {
        'items': [for (final c in page) _view(c)],
        'nextBefore': done.length > limit
            ? (page.last['start'] as DateTime).toUtc().toIso8601String()
            : null,
      });
    }
    if (parts.length == 4 && parts[2] == 'registrations') {
      final same = mine.where((c) => c['key'] == parts[3]);
      if (same.isEmpty) return _err(404, 'NOT_FOUND');
      return _ok(200, {'challenge': _view(same.first)});
    }
    // Everything below addresses one challenge. Somebody else's challenge
    // looks exactly like one that does not exist.
    final found = mine.where((c) => c['id'] == parts[2]);
    if (found.isEmpty) return _err(404, 'NOT_FOUND');
    final c = found.first;
    if (parts.length == 3 && r.method == 'GET') {
      return _ok(200, {'challenge': _view(c)});
    }
    if (parts.length == 4 && r.method == 'POST') {
      switch (parts[3]) {
        case 'complete':
          if (c['status'] == 'active') {
            return _err(409, 'TOO_EARLY', {
              'secondsRemaining': (c['end'] as DateTime)
                  .difference(now)
                  .inSeconds,
            });
          }
          return _ok(200, {'challenge': _view(c)});
        case 'end-early':
          if (c['status'] != 'active') return _err(409, 'CHALLENGE_NOT_ACTIVE');
          return _err(409, 'PAYMENTS_UNAVAILABLE', {
            'paymentRequired': true,
            'amountRupees': c['amount'],
          });
        case 'emergency':
          final id = body['useId'];
          if (emergencyUses.any((u) => u['id'] == id)) {
            return _ok(200, {'challenge': _view(c), 'duplicate': true});
          }
          if (c['status'] != 'active') return _err(409, 'CHALLENGE_NOT_ACTIVE');
          final used = emergencyUses.where((u) => u['challenge'] == c['id']);
          if (used.length >= (c['limit'] as int)) {
            return _err(409, 'EMERGENCY_LIMIT_EXCEEDED');
          }
          emergencyUses.add({
            'id': id,
            'challenge': c['id'],
            'minutes': body['minutes'],
            'recordedAt': now,
          });
          return _ok(201, {'challenge': _view(c)});
        case 'events':
          for (final e in body['events'] as List) {
            final m = (e as Map).cast<String, Object?>();
            if (!events.any((x) => x['id'] == m['id'])) {
              events.add({...m, 'challenge': c['id']});
            }
          }
          return _ok(200, {'accepted': (body['events'] as List).length});
      }
    }
    return _err(404, 'NOT_FOUND');
  }
}

/// One phone: its secure storage, saved state, clock and app.
class Phone {
  Phone(this.server, {String androidId = 'aaaa1111bbbb2222'})
    : platform = FakePlatform(rawAndroidId: androidId),
      clock = FakeClock(server.now);

  final ChallengeServer server;
  final FakePlatform platform;
  FakeBridge bridge = FakeBridge();
  final FakeClock clock;

  /// When true the phone's clock follows the server like the real app does.
  bool alignClock = false;

  late HttpCommitBackend backend;
  late InstallationService installation;
  late CommitController app;

  /// Starts (or restarts) the app on this phone.
  Future<CommitController> open() async {
    final api = ApiClient(
      baseUrl: _base,
      transport: server,
      onServerTime: (t, _) async {
        if (alignClock) clock.time = t;
      },
    );
    installation = InstallationService(platform: platform, api: api);
    await installation.start();
    backend = HttpCommitBackend(api: api, installation: installation);
    app = await boot(bridge, clock, backend: backend);
    await pumpEventQueue();
    return app;
  }

  /// Time passes for the phone and the server alike.
  void pass(Duration d) {
    clock.advance(d);
    server.now = server.now.add(d);
    app.tick();
  }
}

void main() {
  late ChallengeServer server;
  late Phone phone;

  setUp(() {
    server = ChallengeServer(DateTime(2026, 10, 5, 10));
    phone = Phone(server);
  });

  Map<String, Object?> only() => server.challenges.single;

  group('creating a challenge', () {
    test(
      'the server decides ID, start and end; the phone sends no times',
      () async {
        final app = await phone.open();
        phone.clock.advance(const Duration(hours: 3)); // phone clock is wrong
        await app.startInstagram(minutes: 60, amount: 500);

        final sent = server.requests.lastWhere((r) => r.method == 'POST');
        final body = (jsonDecode(sent.body!) as Map).keys;
        expect(body, isNot(contains('startTime')));
        expect(body, isNot(contains('endTime')));
        expect(body, isNot(contains('status')));
        expect(body, isNot(contains('installationId')));
        expect(
          sent.headers['idempotency-key'],
          matches(r'^[A-Za-z0-9_-]{16,128}$'),
        );

        final c = app.active!;
        expect(c.id, only()['id']);
        expect(c.serverIssued, isTrue);
        expect(c.startTime, server.now);
        expect(c.endTime, server.now.add(const Duration(minutes: 60)));
        expect(c.commitmentAmount, 500);
      },
    );

    test('offline: no challenge starts and nothing is invented', () async {
      final app = await phone.open();
      server.offline = true;
      await expectLater(
        app.startInstagram(),
        throwsA(
          isA<CommitmentException>().having(
            (e) => e.error,
            'error',
            CommitmentError.serverUnavailable,
          ),
        ),
      );
      expect(app.active, isNull);
      expect(server.challenges, isEmpty);
    });

    test(
      'answer lost: the same key finds the one challenge, no duplicate',
      () async {
        final app = await phone.open();
        server.dropCreateAnswer = true;
        await expectLater(
          app.startInstagram(),
          throwsA(isA<CommitmentException>()),
        );
        expect(app.active, isNull);
        expect(app.pendingRegistration, isNotNull);
        expect(server.challenges, hasLength(1));

        // The app is killed and reopened.
        server.dropCreateAnswer = false;
        final again = await phone.open();
        await again.syncWithBackend();
        expect(again.active!.id, only()['id']);
        expect(again.pendingRegistration, isNull);
        expect(server.challenges, hasLength(1));
      },
    );

    test('request never arrived: the pending record is dropped', () async {
      final app = await phone.open();
      server.offline = true;
      await expectLater(
        app.startInstagram(),
        throwsA(isA<CommitmentException>()),
      );
      server.offline = false;
      await app.syncWithBackend();
      expect(app.pendingRegistration, isNull);
      expect(app.active, isNull);
      expect(server.challenges, isEmpty);
    });

    test(
      'repeating a create with the same key returns the same challenge',
      () async {
        await phone.open();
        final request = sampleRequest(phone.clock);
        final a = await phone.backend.registerChallenge(
          request,
          idempotencyKey: 'k' * 32,
        );
        final b = await phone.backend.registerChallenge(
          request,
          idempotencyKey: 'k' * 32,
        );
        expect(b.challengeId, a.challengeId);
        expect(server.challenges, hasLength(1));
      },
    );

    test('a second active challenge is refused by the server', () async {
      await phone.open();
      final request = sampleRequest(phone.clock);
      await phone.backend.registerChallenge(request, idempotencyKey: 'a' * 32);
      await expectLater(
        phone.backend.registerChallenge(request, idempotencyKey: 'b' * 32),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'ACTIVE_CHALLENGE_EXISTS',
          ),
        ),
      );
      expect(server.challenges, hasLength(1));
    });

    test('an amount the server refuses creates nothing', () async {
      await phone.open();
      await expectLater(
        phone.backend.registerChallenge(
          sampleRequest(phone.clock, amount: 50),
          idempotencyKey: 'c' * 32,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(server.challenges, isEmpty);
    });
  });

  group('offline behaviour', () {
    test('protection continues while the server is unreachable', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 120);
      server.offline = true;
      phone.pass(const Duration(minutes: 30));
      await app.syncWithBackend();
      expect(app.active, isNotNull);
      expect(app.active!.status, CommitmentStatus.active);

      // Restart while offline: still blocked, from the phone's own record.
      final again = await phone.open();
      expect(again.active!.status, CommitmentStatus.active);
      expect(jsonDecode(phone.bridge.disk!)['commitments'], hasLength(1));
    });

    test(
      'emergency access works offline and is recorded later, once',
      () async {
        final app = await phone.open();
        await app.startInstagram(minutes: 120, emergencyLimit: 2);
        server.offline = true;
        await app.startEmergency();
        expect(app.active!.status, CommitmentStatus.emergency);
        await app.flushOutbox();
        expect(server.emergencyUses, isEmpty);
        expect(app.outbox, isNotEmpty);

        server.offline = false;
        await app.flushOutbox();
        expect(server.emergencyUses, hasLength(1));
        expect(server.emergencyUses.single['minutes'], 5);
        expect(app.outbox, isEmpty);
      },
    );

    test('a retried emergency report is not counted twice', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 120, emergencyLimit: 2);
      await app.startEmergency();
      final queued = [...app.outbox];
      await phone.backend.reportEvents(queued);
      await phone.backend.reportEvents(queued); // answer was lost, sent again
      expect(server.emergencyUses, hasLength(1));
    });

    test(
      'a failed delivery keeps everything queued across a restart',
      () async {
        final app = await phone.open();
        await app.startInstagram(minutes: 120, emergencyLimit: 1);
        await app.startEmergency();
        server.intercept = (r) => r.uri.path.endsWith('/emergency')
            ? ApiRawResponse(
                503,
                '{"code":"SERVER_ERROR","retryable":true}',
                const {},
              )
            : null;
        await app.flushOutbox();
        expect(app.outbox, isNotEmpty);

        final again = await phone.open();
        expect(again.outbox, isNotEmpty);
        server.intercept = null;
        await again.flushOutbox();
        expect(again.outbox, isEmpty);
        expect(server.emergencyUses, hasLength(1));
      },
    );

    test('integrity observations reach the server once each', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 120);
      final id = app.active!.id;
      final events = [
        for (final t in [
          IntegrityEvent.forceStopped,
          IntegrityEvent.protectionLost,
          ChallengeEvent.clockJump,
        ])
          ChallengeEvent(
            eventId: IdempotencyKey.generate(),
            challengeId: id,
            type: t,
            at: phone.clock.time,
          ),
      ];
      await phone.backend.reportEvents(events);
      await phone.backend.reportEvents(events);
      expect(server.events.map((e) => e['type']), [
        'force_stopped',
        'protection_lost',
        'clock_jump',
      ]);
    });
  });

  group('completion', () {
    test(
      'the phone cannot complete early: the server answers TOO_EARLY',
      () async {
        final app = await phone.open();
        await app.startInstagram(minutes: 60);
        final id = app.active!.id;
        await phone.backend.reportEvents([
          ChallengeEvent(
            eventId: IdempotencyKey.generate(),
            challengeId: id,
            type: ChallengeEvent.completedOnDevice,
            at: phone.clock.time,
          ),
        ]);
        expect(only()['status'], 'active');
        expect(server.count('POST', '/complete'), 1);
      },
    );

    test(
      'at the end time both sides complete; payment stays untouched',
      () async {
        final app = await phone.open();
        await app.startInstagram(minutes: 60);
        phone.pass(const Duration(minutes: 61));
        await app.syncWithBackend();
        expect(app.active, isNull);
        expect(app.history.first.status, CommitmentStatus.completed);
        expect(app.history.first.payment, isNull);
        expect(only()['status'], 'completed');
        expect(app.outbox, isEmpty);
      },
    );

    test(
      'phone clock moved forward: the challenge comes back as active',
      () async {
        final app = await phone.open();
        await app.startInstagram(minutes: 60);
        // Only the phone's clock jumps; the server's does not.
        phone.clock.advance(const Duration(hours: 5));
        app.tick();
        expect(app.active, isNull, reason: 'the phone believed its own clock');

        // Online again: the server's time replaces the phone's.
        phone.alignClock = true;
        await app.syncWithBackend();
        expect(app.active, isNotNull);
        expect(app.active!.status, CommitmentStatus.active);
        expect(app.active!.endTime, only()['end']);
        expect(only()['status'], 'active');
        await app.flushOutbox();
        expect(server.events.map((e) => e['type']), contains('clock_jump'));
      },
    );

    test('phone clock moved back: the server completion wins', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 60);
      server.now = server.now.add(const Duration(minutes: 90)); // real time
      await app.syncWithBackend();
      expect(app.active, isNull);
      expect(app.history.first.status, CommitmentStatus.completed);
    });

    test('a finished challenge cannot be changed any more', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 60, emergencyLimit: 2);
      final id = app.active!.id;
      phone.pass(const Duration(minutes: 61));
      await app.syncWithBackend();

      await phone.backend.reportEvents([
        ChallengeEvent(
          eventId: IdempotencyKey.generate(),
          challengeId: id,
          type: ChallengeEvent.emergencyUsed,
          at: phone.clock.time,
        ),
      ]);
      expect(server.emergencyUses, isEmpty);
      final decision = await phone.backend.authorizePaymentAttempt(
        id,
        idempotencyKey: 'e' * 32,
      );
      expect(decision.allowed, isFalse);
      expect(only()['status'], 'completed');
    });
  });

  group('ending early', () {
    test(
      'is refused without a payment system; the challenge stays active',
      () async {
        final app = await phone.open();
        await app.startInstagram(minutes: 120);
        final decision = await phone.backend.authorizePaymentAttempt(
          app.active!.id,
          idempotencyKey: 'f' * 32,
        );
        expect(decision.allowed, isFalse);
        expect(decision.current?.status, PaymentStatus.notStarted);
        await app.syncWithBackend();
        expect(app.active!.status, CommitmentStatus.active);
        expect(app.active!.payment, isNull);
        expect(only()['status'], 'active');
      },
    );

    test('offline: the request fails and nothing is ended', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 120);
      server.offline = true;
      await expectLater(
        phone.backend.authorizePaymentAttempt(
          app.active!.id,
          idempotencyKey: 'g' * 32,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(app.active!.status, CommitmentStatus.active);
    });
  });

  group('ending early through the app', () {
    // The dormant payment path; the released app refuses before this.
    setUp(withDormantPayments);

    test('online: refused, still active, nothing paid', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 120);
      final outcome = await app.endChallengeWithPayment();
      expect(outcome.status, isNot(PaymentStatus.successful));
      expect(app.active, isNotNull);
      expect(app.active!.isLive, isTrue);
      expect(only()['status'], 'active');
      expect(server.count('POST', '/end-early'), 1);

      final again = await phone.open();
      await again.syncWithBackend();
      expect(again.active!.isLive, isTrue);
      expect(
        again.history.where((c) => c.status == CommitmentStatus.endedEarly),
        isEmpty,
      );
    });

    test('offline: still active after the connection returns', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 120);
      server.offline = true;
      final outcome = await app.endChallengeWithPayment();
      expect(outcome.status, isNot(PaymentStatus.successful));
      expect(app.active!.isLive, isTrue);
      server.offline = false;
      await app.syncWithBackend();
      expect(app.active!.isLive, isTrue);
      expect(only()['status'], 'active');
    });
  });

  group('restore and conflicts', () {
    test(
      'cleared app data: the same installation gets its challenge back',
      () async {
        final app = await phone.open();
        await app.startInstagram(minutes: 120, emergencyLimit: 2);
        await app.startEmergency();
        await app.flushOutbox();
        final id = app.active!.id;
        final end = app.active!.endTime;

        // Reinstall: saved state and secure storage are both gone.
        phone.bridge = FakeBridge();
        phone.platform.store.clear();
        final again = await phone.open();
        await again.syncWithBackend();
        expect(phone.installation.identity, isNotNull);
        expect(again.active!.id, id);
        expect(again.active!.endTime, end);
        expect(again.active!.emergencyAccessCount, 1);
        expect(again.active!.packageNames, [instagram]);
        await again.flushOutbox();
        expect(
          server.events.map((e) => e['type']),
          contains('restored_on_device'),
        );
        expect(server.challenges, hasLength(1));
      },
    );

    test('a challenge that already ended is not restored', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 60);
      phone.bridge = FakeBridge();
      phone.pass(const Duration(minutes: 61));
      final again = await phone.open();
      await again.syncWithBackend();
      expect(again.active, isNull);
    });

    test('another phone never sees or changes this challenge', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 120, emergencyLimit: 2);
      final id = app.active!.id;

      final other = Phone(server, androidId: 'cccc3333dddd4444');
      final otherApp = await other.open();
      await otherApp.syncWithBackend();
      expect(otherApp.active, isNull);
      expect(await other.backend.fetchChallenge(id), isNull);
      expect(await other.backend.currentChallenge(), isNull);
      await other.backend.reportEvents([
        ChallengeEvent(
          eventId: IdempotencyKey.generate(),
          challengeId: id,
          type: ChallengeEvent.emergencyUsed,
          at: other.clock.time,
        ),
      ]);
      expect(server.emergencyUses, isEmpty);
      final d = await other.backend.authorizePaymentAttempt(
        id,
        idempotencyKey: 'h' * 32,
      );
      expect(d.allowed, isFalse);
      expect(only()['status'], 'active');
    });

    test('a local challenge the server does not know keeps blocking', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 120);
      server.challenges.clear(); // the server lost it
      await app.syncWithBackend();
      expect(app.active, isNotNull);
      expect(app.active!.status, CommitmentStatus.active);
    });

    test(
      'a challenge from before the server existed is never uploaded',
      () async {
        // Started with the stand-in backend (version 2.7.0 and earlier).
        final old = await boot(phone.bridge, phone.clock);
        await old.startInstagram(minutes: 120);
        final id = old.active!.id;

        final app = await phone.open();
        await app.syncWithBackend();
        expect(app.active!.id, id);
        expect(server.challenges, isEmpty);
        expect(
          server.requests.where((r) => r.uri.path.contains(id)),
          isEmpty,
          reason: 'a local-only ID is never sent',
        );
        phone.pass(const Duration(minutes: 121));
        expect(app.active, isNull);
        expect(app.history.first.status, CommitmentStatus.completed);
      },
    );

    test('server terms replace changed local terms', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 120);
      // Somebody edits the saved file to end the challenge sooner.
      final doc = jsonDecode(phone.bridge.disk!) as Map<String, Object?>;
      final saved = (doc['commitments'] as List).single as Map;
      final endKey = saved.keys.firstWhere(
        (k) => '$k'.toLowerCase().contains('end') && saved[k] != null,
      );
      final original = saved[endKey];
      saved[endKey] =
          saved[saved.keys.firstWhere(
            (k) => '$k'.toLowerCase().contains('start') && saved[k] != null,
          )];
      expect(saved[endKey], isNot(original));
      phone.bridge.disk = jsonEncode(doc);

      final again = await phone.open();
      await again.syncWithBackend();
      // Whatever the phone made of the edited file, the server still has the
      // challenge running with its original end time.
      expect(only()['status'], 'active');
      expect(only()['end'], server.now.add(const Duration(minutes: 120)));
      expect(again.active, isNotNull);
      expect(again.active!.endTime, only()['end']);
    });

    test('a rejected credential is recovered, the challenge is kept', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 120);
      final id = app.active!.id;
      // The server no longer accepts this credential.
      server.installations.single['credential'] = 'x' * 43;
      await app.syncWithBackend();
      expect(
        app.active!.id,
        id,
        reason: 'protection never depends on the server',
      );
      await pumpEventQueue();
      expect(server.count('POST', '/installations/recover'), 1);
      await app.syncWithBackend();
      expect((await phone.backend.currentChallenge())!.terms.challengeId, id);
    });
  });

  group('history', () {
    test('pages through finished challenges, newest first', () async {
      final app = await phone.open();
      for (var i = 0; i < 5; i++) {
        await app.startInstagram(minutes: 10);
        phone.pass(const Duration(minutes: 11));
        await app.syncWithBackend();
      }
      final first = await phone.backend.fetchHistory(limit: 2);
      expect(first.items, hasLength(2));
      expect(first.nextBefore, isNotNull);
      final second = await phone.backend.fetchHistory(
        limit: 2,
        before: first.nextBefore,
      );
      final third = await phone.backend.fetchHistory(
        limit: 2,
        before: second.nextBefore,
      );
      final ids = [
        for (final p in [first, second, third])
          for (final c in p.items) c.terms.challengeId,
      ];
      expect(ids.toSet(), hasLength(5));
      expect(third.nextBefore, isNull);
      expect(
        first.items.first.terms.startTime.isAfter(
          third.items.last.terms.startTime,
        ),
        isTrue,
      );
    });
  });

  group('what the client refuses', () {
    Future<void> answerWith(Map<String, Object?> challenge) async {
      await phone.open();
      server.intercept = (r) => r.uri.path.endsWith('/active')
          ? ApiRawResponse(
              200,
              jsonEncode({'challenge': challenge, 'epochMs': 1}),
              const {},
            )
          : null;
    }

    final good = {
      'id': '10000000-0000-4000-8000-000000000009',
      'status': 'active',
      'startTime': '2026-10-05T04:30:00.000Z',
      'endTime': '2026-10-05T06:30:00.000Z',
      'actualEndTime': null,
      'durationMinutes': 120,
      'amountRupees': 500,
      'emergencyLimit': 1,
      'emergencyMinutes': 5,
      'emergencyUsed': 0,
      'consentVersion': 'v1',
      'consentAcceptedAt': '2026-10-05T04:30:00.000Z',
      'apps': [
        {'packageName': instagram, 'appName': 'Instagram'},
      ],
    };

    test('a well-formed answer is accepted', () async {
      await answerWith(good);
      final c = await phone.backend.currentChallenge();
      expect(c!.terms.amountRupees, 500);
      expect(c.payment, isNull);
    });

    for (final bad in <String, Object?>{
      'id': 'not-a-uuid',
      'status': 'paid',
      'endTime': '2026-10-05T04:00:00.000Z',
      'amountRupees': 99999,
      'startTime': 'yesterday',
      'emergencyLimit': 99,
    }.entries) {
      test('a malformed ${bad.key} is refused, never stored', () async {
        await answerWith({...good, bad.key: bad.value});
        await expectLater(
          phone.backend.currentChallenge(),
          throwsA(
            isA<ApiException>().having(
              (e) => e.code,
              'code',
              ApiException.malformedResponse,
            ),
          ),
        );
        await phone.app.syncWithBackend();
        expect(phone.app.active, isNull);
      });
    }

    test('no request ever carries a credential in its address', () async {
      final app = await phone.open();
      await app.startInstagram(minutes: 10, emergencyLimit: 1);
      await app.startEmergency();
      await app.flushOutbox();
      await phone.backend.fetchHistory(limit: 5);
      final credential = phone.installation.identity!.credential;
      for (final r in server.requests) {
        expect('${r.uri}', isNot(contains(credential)));
        if (r.uri.path.contains('/v1/challenges')) {
          expect(r.body ?? '', isNot(contains(credential)));
        }
      }
    });
  });

  group('server time', () {
    test('a wrong phone clock is replaced by the server clock', () async {
      final bridge = FakeBridge();
      final clock = FakeClock(DateTime(2026, 10, 5, 15));
      final aligner = ServerTimeAligner(bridge: bridge, clock: clock);
      final serverNow = DateTime(2026, 10, 5, 10);
      await aligner.onServerTime(serverNow, const Duration(milliseconds: 400));
      expect(bridge.anchored.single, serverNow.millisecondsSinceEpoch + 200);
      expect(aligner.lastCorrection!.inHours, 4);
    });

    test('a small difference or a slow answer changes nothing', () async {
      final bridge = FakeBridge();
      final clock = FakeClock(DateTime(2026, 10, 5, 10, 0, 1));
      final aligner = ServerTimeAligner(bridge: bridge, clock: clock);
      await aligner.onServerTime(DateTime(2026, 10, 5, 10), Duration.zero);
      clock.advance(const Duration(hours: 2));
      await aligner.onServerTime(
        DateTime(2026, 10, 5, 10),
        const Duration(seconds: 9),
      );
      expect(bridge.anchored, isEmpty);
    });
  });
}
