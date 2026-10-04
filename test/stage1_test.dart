// Stage 1 (U1-U6). FakeBackend stands in for a real server and FakePayments
// for a provider; neither ships and no real payment exists anywhere.
import 'dart:convert';

import 'package:app/core/backend.dart';
import 'package:app/core/commitment.dart';
import 'package:app/core/commitment_engine.dart';
import 'package:app/core/payment.dart';
import 'package:app/data/commit_controller.dart';
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

  group('U1: registration cannot leave an orphan challenge', () {
    test('the key and request are saved before the server is called', () async {
      final c = await start();
      server.offline = true;
      await expectLater(
        c.startInstagram(),
        refused(CommitmentError.serverUnavailable),
      );
      final pending = doc()['pendingRegistration'] as Map;
      expect(pending['idempotencyKey'], hasLength(32));
      expect((pending['request'] as Map)['amountRupees'], 100);
      expect(c.active, isNull);
    });

    test(
      'server created it but the reply was lost: adopted on next start',
      () async {
        final first = await start();
        server.dropNextReply = true;
        await expectLater(
          first.startInstagram(minutes: 1440, amount: 100),
          refused(CommitmentError.serverUnavailable),
        );
        expect(first.active, isNull);
        expect(server.challenges, hasLength(1), reason: 'exists on the server');

        clock.advance(const Duration(minutes: 4));
        final second = await start(); // app restarted
        await second.syncWithBackend();
        final a = second.active!;
        expect(a.id, server.challenges.keys.single);
        expect(a.startTime, clock.time.subtract(const Duration(minutes: 4)));
        expect(a.commitmentAmount, 100);
        expect(a.consent, isNotNull);
        expect(second.pendingRegistration, isNull);
        expect(doc()['pendingRegistration'], isNull);
        expect(server.challenges, hasLength(1), reason: 'no second challenge');
        expect(second.notice, isNotNull);
      },
    );

    test(
      'server never received it: the request is dropped, nothing starts',
      () async {
        final first = await start();
        server.offline = true;
        await expectLater(first.startInstagram(), throwsA(anything));
        server.offline = false;

        final second = await start();
        await second.syncWithBackend();
        expect(second.active, isNull);
        expect(second.pendingRegistration, isNull);
        expect(server.challenges, isEmpty, reason: 'resuming never creates');
      },
    );

    test('a new challenge waits until the earlier one is settled', () async {
      final c = await start();
      server.dropNextReply = true;
      await expectLater(c.startInstagram(), throwsA(anything));
      server.offline = true;
      await expectLater(
        c.startInstagram(),
        refused(CommitmentError.registrationUnresolved),
      );
      server.offline = false;
      // Back online: the earlier challenge turns out to exist, so a second
      // one is refused instead of being created next to it.
      await expectLater(
        c.startInstagram(),
        refused(CommitmentError.duplicateActive),
      );
      expect(server.challenges, hasLength(1));
      expect(c.active, isNotNull);
    });

    test(
      'with the local stand-in a leftover request is simply discarded',
      () async {
        final d = {
          'version': 2,
          'onboarded': true,
          'commitments': [],
          'pendingRegistration': {
            'idempotencyKey': 'abc',
            'createdAt': clock.time.millisecondsSinceEpoch,
            'request': sampleRequest(clock).toJson(),
          },
        };
        bridge.disk = jsonEncode(d);
        final c = await boot(bridge, clock);
        expect(c.pendingRegistration, isNull);
        expect(c.active, isNull);
        await c.startInstagram();
        expect(c.active, isNotNull);
      },
    );
  });

  group('U2: restore after reinstall, device change or cleared data', () {
    test(
      'a fresh install gets the running challenge back from the server',
      () async {
        final old = await start();
        await old.createCommitment(
          consentAccepted: true,
          apps: const [
            AppRef(instagram, 'Instagram'),
            AppRef(youtube, 'YouTube'),
          ],
          durationMinutes: 1440,
          amount: 100,
          emergencyLimit: 2,
          emergencyMinutes: 5,
        );
        final original = old.active!;
        clock.advance(const Duration(hours: 1));
        await old.startEmergency();
        await old.flushOutbox();
        clock.advance(const Duration(hours: 2));

        // New phone / reinstall: empty storage, same account.
        bridge = FakeBridge();
        final fresh = await start();
        await fresh.syncWithBackend();
        final a = fresh.active!;
        expect(a.id, original.id);
        expect(a.packageNames, [instagram, youtube]);
        expect(a.endTime, original.endTime);
        expect(a.commitmentAmount, 100);
        expect(a.emergencyLimit, 2);
        expect(
          a.emergencyRemaining,
          1,
          reason: 'the used one is not given back',
        );
        expect(a.serverIssued, isTrue);
        expect(CommitmentEngine.isBlocking(a, fresh.now), isTrue);
        expect(fresh.notice, 'Your running challenge was restored.');
      },
    );

    test('a payment already made is restored with it', () async {
      final old = await start();
      await old.startInstagram();
      final id = old.active!.id;
      clock.advance(const Duration(hours: 1));
      pay.server[FakeBackend.ref(id)] = const PaymentOutcome(
        PaymentStatus.pending,
      );

      bridge = FakeBridge();
      final fresh = await start();
      await fresh.syncWithBackend();
      expect(fresh.active!.payment!.status, PaymentStatus.pending);
      expect(pay.payCalls, 0);
    });

    test(
      'nothing is restored when the server has no running challenge',
      () async {
        final fresh = await start();
        await fresh.syncWithBackend();
        expect(fresh.active, isNull);
        expect(fresh.history, isEmpty);
      },
    );
  });

  group('U3: events reach the backend', () {
    test(
      'emergency use, interruption and completion are reported once',
      () async {
        final c = await start();
        await c.startInstagram(minutes: 120, emergencyLimit: 1);
        final id = c.active!.id;
        clock.advance(const Duration(minutes: 10));
        await c.startEmergency();
        clock.advance(const Duration(minutes: 10));
        bridge.nativeEvents.add({
          'type': IntegrityEvent.forceStopped,
          'at': clock.time.millisecondsSinceEpoch,
        });
        await c.onResume();
        clock.advance(const Duration(hours: 2));
        c.tick();
        await c.flushOutbox();

        expect(server.events.map((e) => e.type), [
          ChallengeEvent.emergencyUsed,
          IntegrityEvent.forceStopped,
          IntegrityEvent.protectionRestored,
          ChallengeEvent.completedOnDevice,
        ]);
        expect(server.events.every((e) => e.challengeId == id), isTrue);
        expect(c.outbox, isEmpty);

        // Sending again changes nothing.
        await c.flushOutbox();
        expect(server.events, hasLength(4));
      },
    );

    test('events wait while offline and survive a restart', () async {
      final c = await start();
      await c.startInstagram(emergencyLimit: 1);
      server.offline = true;
      clock.advance(const Duration(hours: 1));
      await c.startEmergency();
      await c.flushOutbox();
      expect(c.outbox, hasLength(1));
      expect((doc()['outbox'] as List), hasLength(1));

      final again = await start(); // still offline
      expect(again.outbox, hasLength(1));
      server.offline = false;
      await again.flushOutbox();
      expect(again.outbox, isEmpty);
      expect(server.events.single.type, ChallengeEvent.emergencyUsed);
    });

    test('reporting an event never charges or ends a challenge', () async {
      final c = await start();
      await c.startInstagram();
      bridge.accessibility = false;
      bridge.usage = false;
      clock.advance(const Duration(hours: 1));
      await c.onResume();
      await c.flushOutbox();
      expect(server.events.single.type, IntegrityEvent.protectionLost);
      expect(c.active!.status, CommitmentStatus.active);
      expect(c.active!.payment, isNull);
      expect(pay.payCalls, 0);
    });

    test('nothing is queued for a challenge only the stand-in knows', () async {
      final c = await boot(bridge, clock);
      await c.startInstagram(emergencyLimit: 1);
      clock.advance(const Duration(hours: 1));
      await c.startEmergency();
      expect(c.outbox, isEmpty);
    });
  });

  group('U4: a pending payment does not sit forever', () {
    test('it is re-checked while the app is open, without a tap', () async {
      final c = await start();
      await c.startInstagram();
      final id = c.active!.id;
      clock.advance(const Duration(hours: 1));
      pay.onPay = (_) => const PaymentOutcome(PaymentStatus.pending);
      await c.endChallengeWithPayment();
      expect(c.active!.payment!.status, PaymentStatus.pending);

      // The provider confirms later.
      pay.server[FakeBackend.ref(id)] = PaymentOutcome(
        PaymentStatus.successful,
        transactionId: 'txn_poll',
        paidAt: clock.time,
      );
      for (var i = 0; i < 15; i++) {
        c.tick();
      }
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.active, isNull);
      expect(c.byId(id)!.status, CommitmentStatus.endedEarly);
      expect(pay.payCalls, 1);
    });

    test('expiry is stored and an expired attempt is flagged', () async {
      final c = await start();
      await c.startInstagram(minutes: 120);
      clock.advance(const Duration(minutes: 30));
      pay.onPay = (_) => const PaymentOutcome(PaymentStatus.pending);
      await c.endChallengeWithPayment();
      final p = c.active!.payment!;
      expect(p.expiresAt, c.active!.endTime);
      expect(p.isExpired(c.now), isFalse);
      expect(p.isExpired(c.active!.endTime), isTrue);
    });

    test(
      'an authorisation that has already expired opens no checkout',
      () async {
        final c = await start();
        await c.startInstagram(minutes: 120);
        final id = c.active!.id;
        clock.advance(const Duration(minutes: 30));
        // A server answer that is already out of date.
        server.decisionOverride = PaymentAttemptDecision.allowed(
          reference: FakeBackend.ref(id),
          amountRupees: 100,
          attempt: 1,
          expiresAt: clock.time.subtract(const Duration(seconds: 1)),
        );
        pay.succeedWith('txn', clock.time);
        final out = await c.endChallengeWithPayment();
        expect(out.status, PaymentStatus.cancelled);
        expect(pay.payCalls, 0);
        expect(c.active, isNotNull);
      },
    );
  });

  group('U5: refund states', () {
    test(
      'a late payment and its refund are shown as the server reports them',
      () async {
        final c = await start();
        await c.startInstagram(minutes: 60);
        final id = c.active!.id;
        clock.advance(const Duration(minutes: 20));
        pay.onPay = (_) => const PaymentOutcome(PaymentStatus.pending);
        await c.endChallengeWithPayment();

        // The challenge finishes by itself; then the capture arrives late.
        clock.advance(const Duration(hours: 1));
        c.tick();
        expect(c.byId(id)!.status, CommitmentStatus.completed);
        pay.server[FakeBackend.ref(id)] = PaymentOutcome(
          PaymentStatus.successful,
          transactionId: 'txn_late',
          paidAt: clock.time,
          refund: RefundStatus.pending,
        );
        await c.reconcilePayment();
        var p = c.byId(id)!.payment!;
        expect(c.byId(id)!.status, CommitmentStatus.completed);
        expect(p.status, PaymentStatus.successful);
        expect(p.refund, RefundStatus.pending);
        expect(p.needsFollowUp, isTrue);
        expect(
          CommitmentEngine.stateOf(c.byId(id)!, c.now),
          ChallengeState.paymentVerified,
        );

        // Later the server reports the refund as done.
        pay.server[FakeBackend.ref(id)] = PaymentOutcome(
          PaymentStatus.successful,
          transactionId: 'txn_late',
          paidAt: clock.time,
          refund: RefundStatus.refunded,
          refundedAt: clock.time,
        );
        await c.reconcilePayment();
        p = c.byId(id)!.payment!;
        expect(p.refund, RefundStatus.refunded);
        expect(p.needsFollowUp, isFalse);
        expect(pay.payCalls, 1);

        // Survives a restart and a local reset.
        final again = await start();
        await again.resetData();
        expect(again.byId(id)!.payment!.refund, RefundStatus.refunded);
      },
    );

    test('refund fields round-trip and default to none', () {
      final r = PaymentRecord(
        reference: 'r',
        amountRupees: 100,
        status: PaymentStatus.successful,
        initiatedAt: clock.time,
        refund: RefundStatus.pending,
      );
      expect(PaymentRecord.fromJson(r.toJson()).refund, RefundStatus.pending);
      final old = Map<String, Object?>.from(r.toJson())..remove('refund');
      expect(PaymentRecord.fromJson(old).refund, RefundStatus.none);
      expect(RefundStatus.values.map((s) => s.wire), [
        'NONE',
        'REFUND_PENDING',
        'REFUNDED',
        'REFUND_FAILED',
      ]);
    });
  });

  group('U6: consent is recorded', () {
    test('no challenge starts without consent', () async {
      final c = await start();
      await expectLater(
        c.createCommitment(
          consentAccepted: false,
          apps: const [AppRef(instagram, 'Instagram')],
          durationMinutes: 60,
          amount: 100,
        ),
        refused(CommitmentError.consentRequired),
      );
      expect(c.active, isNull);
      expect(server.requests, isEmpty);
      expect(doc()['pendingRegistration'], isNull);
    });

    test(
      'version, time and amount are stored and sent to the backend',
      () async {
        final c = await start();
        await c.startInstagram(amount: 250); // a custom amount
        final consent = c.active!.consent!;
        expect(consent.version, CommitmentEngine.consentVersion);
        expect(consent.acceptedAt, clock.time);
        expect(consent.amountRupees, 250);
        expect(server.requests.single.consent.version, consent.version);
        expect(server.requests.single.consent.amountRupees, 250);

        final again = await start();
        expect(again.active!.consent!.acceptedAt, consent.acceptedAt);
      },
    );

    test('the consent wording names the amount', () {
      expect(
        CommitmentEngine.consentText('₹250'),
        'By starting this challenge, I understand that ending the challenge '
        'early will require payment of ₹250.',
      );
    });

    test('challenges saved before 2.4 load without a consent record', () {
      final j = CommitmentEngine.create(
        id: 'x',
        apps: const [AppRef(instagram, 'Instagram')],
        durationMinutes: 60,
        amount: 100,
        now: clock.time,
      ).toJson()..remove('consent');
      expect(Commitment.fromJson(j).consent, isNull);
    });
  });

  group('amounts', () {
    test(
      'suggestions run from 100 to 10,000 and custom amounts still work',
      () async {
        expect(CommitmentEngine.amounts, [100, 500, 1000, 2500, 5000, 10000]);
        final c = await boot(bridge, clock);
        await c.startInstagram(amount: 275);
        expect(c.active!.commitmentAmount, 275);
      },
    );
    test('amounts below 100 or above 10,000 never start a challenge', () async {
      for (final bad in [99, 10001]) {
        final c = await boot(FakeBridge(), clock);
        await expectLater(
          c.startInstagram(amount: bad),
          throwsA(isA<CommitmentException>()),
        );
        expect(c.active, isNull);
      }
    });
  });
}
