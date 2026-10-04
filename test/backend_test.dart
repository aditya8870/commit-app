// Proves the phone obeys the backend. FakeBackend is a test double for a real
// server; FakePayments is a test double for a provider. Neither ships.
import 'dart:convert';

import 'package:app/core/backend.dart';
import 'package:app/core/commitment.dart';
import 'package:app/core/commitment_engine.dart';
import 'package:app/core/payment.dart';
import 'package:app/data/commit_controller.dart';
import 'package:app/data/standin_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeBridge bridge;
  late FakeClock clock;
  late FakePayments pay;
  late FakeBackend server;

  setUp(() {
    withDormantPayments();
    bridge = FakeBridge();
    clock = FakeClock();
    pay = FakePayments();
    server = FakeBackend(clock, pay);
  });

  Future<CommitController> start() =>
      boot(bridge, clock, payments: pay, backend: server);

  Matcher refused(CommitmentError e) =>
      throwsA(isA<CommitmentException>().having((x) => x.error, 'error', e));

  Map doc() => jsonDecode(bridge.disk!) as Map;
  Map saved() => (doc()['commitments'] as List).last as Map;

  group('server-authoritative challenge', () {
    test('ID, owner, times and amount are the server\'s', () async {
      server.amountOverride = 200; // phone asks for 100
      server.serverClockOffset = const Duration(minutes: 3);
      final c = await start();
      await c.startInstagram(minutes: 1440, amount: 100);
      final a = c.active!;
      expect(a.id, 'srv-ch-1');
      expect(a.ownerUserId, 'user-42');
      expect(a.serverIssued, isTrue);
      expect(a.commitmentAmount, 200);
      expect(a.startTime, clock.time.add(const Duration(minutes: 3)));
      expect(a.endTime, a.startTime.add(const Duration(days: 1)));
      expect(a.registrationKey, server.registrationKeys.single);
      expect(saved()['serverIssued'], isTrue);
    });

    test('no challenge starts if the server cannot be reached', () async {
      final c = await start();
      server.offline = true;
      await expectLater(
        c.startInstagram(),
        refused(CommitmentError.serverUnavailable),
      );
      expect(c.active, isNull);
      expect(c.history, isEmpty);
    });

    test('server terms replace a locally edited end time and amount', () async {
      final c = await start();
      await c.startInstagram(minutes: 1440, amount: 100);
      final real = c.active!;

      // Someone edits the saved file: shorter challenge, smaller amount.
      final d = doc();
      final rec = (d['commitments'] as List).single as Map;
      rec['endTime'] = clock.time
          .add(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      rec['commitmentAmount'] = 10;
      bridge.disk = jsonEncode(d);

      final again = await start();
      await again.syncWithBackend();
      expect(again.active!.endTime, real.endTime);
      expect(again.active!.commitmentAmount, 100);
    });

    test(
      'a payment the server already has ends the challenge on sync',
      () async {
        final c = await start();
        await c.startInstagram();
        final id = c.active!.id;
        clock.advance(const Duration(hours: 2));
        pay.server[FakeBackend.ref(id)] = PaymentOutcome(
          PaymentStatus.successful,
          transactionId: 'txn_web',
          paidAt: clock.time,
        );
        await c.syncWithBackend();
        expect(c.active, isNull);
        expect(c.byId(id)!.status, CommitmentStatus.endedEarly);
        expect(c.byId(id)!.payment!.authoritative, isTrue);
        expect(pay.payCalls, 0, reason: 'the phone never opened a checkout');
      },
    );

    test('server offline during sync changes nothing', () async {
      final c = await start();
      await c.startInstagram();
      final before = jsonEncode(c.active!.toJson());
      server.offline = true;
      await c.syncWithBackend();
      expect(jsonEncode(c.active!.toJson()), before);
      expect(CommitmentEngine.isBlocking(c.active!, c.now), isTrue);
    });
  });

  group('B1: no checkout without server authorisation', () {
    test('reference and amount in the checkout are the server\'s', () async {
      server.amountOverride = 200;
      final c = await start();
      await c.startInstagram(amount: 100);
      final id = c.active!.id;
      clock.advance(const Duration(hours: 1));
      PaymentRequest? seen;
      pay.onPay = (r) {
        seen = r;
        return const PaymentOutcome(PaymentStatus.cancelled);
      };
      await c.endChallengeWithPayment();
      expect(seen!.reference, FakeBackend.ref(id));
      expect(seen!.amountRupees, 200);
      expect(c.active!.payment!.reference, FakeBackend.ref(id));
      expect(c.active!.payment!.amountRupees, 200);
      expect(c.active!.payment!.attempt, 1);
    });

    test(
      'after "failed", a refused authorisation means no new checkout',
      () async {
        final c = await start();
        await c.startInstagram();
        final id = c.active!.id;
        clock.advance(const Duration(hours: 1));
        pay.onPay = (_) => const PaymentOutcome(PaymentStatus.failed);
        await c.endChallengeWithPayment();
        expect(pay.payCalls, 1);
        expect(c.active!.payment!.status, PaymentStatus.failed);

        // The money was in fact debited; the provider told the server.
        pay.server[FakeBackend.ref(id)] = PaymentOutcome(
          PaymentStatus.successful,
          transactionId: 'txn_real',
          paidAt: clock.time,
        );
        final out = await c.endChallengeWithPayment();
        expect(pay.payCalls, 1, reason: 'no second checkout, no second charge');
        expect(out.status, PaymentStatus.successful);
        expect(c.byId(id)!.status, CommitmentStatus.endedEarly);
        expect(c.byId(id)!.payment!.transactionId, 'txn_real');
      },
    );

    test('after "cancelled", the server may allow a new attempt', () async {
      final c = await start();
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      pay.onPay = (_) => const PaymentOutcome(PaymentStatus.cancelled);
      await c.endChallengeWithPayment();
      await c.endChallengeWithPayment();
      expect(pay.payCalls, 2);
      expect(server.attempts, 2);
      expect(c.active!.payment!.attempt, 2);
      expect(c.active, isNotNull);
    });

    test('the server can refuse an attempt outright', () async {
      final c = await start();
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      server.denyWith = const PaymentOutcome(
        PaymentStatus.failed,
        message: 'Too many attempts.',
      );
      final out = await c.endChallengeWithPayment();
      expect(out.message, 'Too many attempts.');
      expect(pay.payCalls, 0);
      expect(c.active, isNotNull);
    });

    test('server unreachable: no checkout, challenge stays active', () async {
      final c = await start();
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      server.offline = true;
      pay.succeedWith('txn', clock.time);
      final out = await c.endChallengeWithPayment();
      expect(out.status, PaymentStatus.networkError);
      expect(pay.payCalls, 0);
      expect(c.active!.status, CommitmentStatus.active);

      // Unknown outcome: the next tap only checks status.
      server.offline = false;
      final next = await c.endChallengeWithPayment();
      expect(next.status, PaymentStatus.notStarted);
      expect(pay.payCalls, 0);
    });

    test(
      'a checkout "success" the server does not confirm is not accepted',
      () async {
        final c = await start();
        await c.startInstagram();
        clock.advance(const Duration(hours: 1));
        pay.onPay = (_) => const PaymentOutcome(
          PaymentStatus.successful,
          transactionId: 'forged',
        );
        final out = await c.endChallengeWithPayment();
        expect(out.status, PaymentStatus.verificationFailed);
        expect(c.active, isNotNull);
        expect(c.active!.payment!.transactionId, isNull);
      },
    );

    test('checkout said "cancelled" but the server has the payment', () async {
      final c = await start();
      await c.startInstagram();
      final id = c.active!.id;
      clock.advance(const Duration(hours: 1));
      pay.onPay = (r) {
        pay.server[r.reference] = PaymentOutcome(
          PaymentStatus.successful,
          transactionId: 'txn_ok',
          paidAt: clock.time,
        );
        return const PaymentOutcome(PaymentStatus.cancelled);
      };
      final out = await c.endChallengeWithPayment();
      expect(out.status, PaymentStatus.successful, reason: 'server wins');
      expect(c.byId(id)!.status, CommitmentStatus.endedEarly);
    });
  });

  group('idempotency keys', () {
    test('each attempt has its own key, saved before the request', () async {
      final c = await start();
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      pay.onPay = (_) => const PaymentOutcome(PaymentStatus.cancelled);
      await c.endChallengeWithPayment();
      final first = c.active!.payment!.idempotencyKey;
      await c.endChallengeWithPayment();
      final second = c.active!.payment!.idempotencyKey;
      expect(first, isNotNull);
      expect(first, hasLength(32));
      expect(second, isNot(first));
      expect(server.attemptKeys, [first, second]);
    });

    test('a status check sends no new attempt key', () async {
      final c = await start();
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      pay.onPay = (_) => const PaymentOutcome(PaymentStatus.pending);
      await c.endChallengeWithPayment();
      await c.endChallengeWithPayment(); // pending -> status check only
      expect(server.attemptKeys, hasLength(1));
    });

    test('the same key always gets the same answer', () async {
      final a = await server.registerChallenge(
        sampleRequest(clock),
        idempotencyKey: 'k1',
      );
      final b = await server.registerChallenge(
        sampleRequest(clock),
        idempotencyKey: 'k1',
      );
      expect(b.challengeId, a.challengeId);
      expect(server.challenges, hasLength(1));
      final keys = {for (var i = 0; i < 50; i++) IdempotencyKey.generate()};
      expect(keys, hasLength(50));
    });
  });

  group('identity', () {
    test(
      'install ID is created once and reused; the server names the user',
      () async {
        final first = await start();
        final id = first.installId;
        expect(id, hasLength(32));
        expect(first.identity!.userId, 'user-42');
        expect(first.identity!.isAuthenticated, isTrue);
        expect(server.lastInstallId, id);

        final second = await start();
        expect(second.installId, id);
      },
    );

    test(
      'the stand-in never claims to be authenticated or authoritative',
      () async {
        final c = await boot(bridge, clock);
        expect(c.backend, isA<StandInBackend>());
        expect(c.backend.isConnected, isFalse);
        expect(c.identity!.isAuthenticated, isFalse);
        await c.startInstagram();
        expect(c.active!.serverIssued, isFalse);
        clock.advance(const Duration(hours: 1));
        await c.endChallengeWithPayment();
        expect(c.active!.payment!.authoritative, isFalse);
        expect(c.active!.payment!.status, PaymentStatus.failed);
      },
    );
  });
}
