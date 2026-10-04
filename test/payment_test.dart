import 'dart:convert';

import 'package:app/core/commitment.dart';
import 'package:app/core/commitment_engine.dart';
import 'package:app/core/payment.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeBridge bridge;
  late FakeClock clock;
  late FakePayments pay;

  setUp(() {
    withDormantPayments();
    bridge = FakeBridge();
    clock = FakeClock();
    pay = FakePayments();
  });

  Matcher refused(CommitmentError e) =>
      throwsA(isA<CommitmentException>().having((x) => x.error, 'error', e));

  Map saved() =>
      ((jsonDecode(bridge.disk!) as Map)['commitments'] as List).single as Map;

  Future<void> expectStillActive(dynamic c, PaymentStatus status) async {
    expect(c.active, isNotNull, reason: 'challenge must stay active');
    expect(c.active!.status, CommitmentStatus.active);
    expect(c.active!.payment!.status, status);
    expect(CommitmentEngine.isBlocking(c.active!, c.now), isTrue);
    expect(saved()['status'], 'ACTIVE');
  }

  test(
    'verified payment ends the challenge early and records everything',
    () async {
      final c = await boot(bridge, clock, payments: pay);
      await c.startInstagram(minutes: 1440, amount: 100);
      final ch = c.active!;
      clock.advance(const Duration(hours: 4, minutes: 18));
      pay.succeedWith('txn_1', clock.time);

      final out = await c.endChallengeWithPayment();
      expect(out.status, PaymentStatus.successful);
      expect(c.active, isNull);

      final done = c.byId(ch.id)!;
      expect(done.status, CommitmentStatus.endedEarly);
      expect(done.appNames, ['Instagram']);
      expect(done.startTime, ch.startTime);
      expect(done.endTime, ch.endTime, reason: 'original end time is kept');
      expect(done.actualEndTime, clock.time);
      expect(done.remainingAtEnd, const Duration(hours: 19, minutes: 42));
      expect(done.commitmentAmount, 100);
      expect(done.payment!.status, PaymentStatus.successful);
      expect(done.payment!.transactionId, 'txn_1');
      expect(done.payment!.paidAt, clock.time);
      expect(done.payment!.reference, 'commit-${ch.id}');
      expect(pay.charges, 1);

      // The native blocker only locks ACTIVE/EMERGENCY records.
      expect(saved()['status'], 'ENDED_EARLY');
      expect(c.pendingCompletion!.id, ch.id);
      expect(c.stats.endedEarly, 1);
      expect(c.stats.completed, 0);

      // Survives a restart.
      final again = await boot(bridge, clock, payments: pay);
      expect(again.active, isNull);
      expect(again.byId(ch.id)!.payment!.transactionId, 'txn_1');
    },
  );

  for (final status in [
    PaymentStatus.cancelled,
    PaymentStatus.failed,
    PaymentStatus.networkError,
    PaymentStatus.pending,
  ]) {
    test('challenge stays active when payment is ${status.name}', () async {
      final c = await boot(bridge, clock, payments: pay);
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      pay.onPay = (_) => PaymentOutcome(status);
      final out = await c.endChallengeWithPayment();
      expect(out.status, status);
      await expectStillActive(c, status);
    });
  }

  test(
    'a client-side "success" that the backend does not confirm is rejected',
    () async {
      final c = await boot(bridge, clock, payments: pay);
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      // Checkout claims success, but the backend has no such payment.
      pay.onPay = (_) => const PaymentOutcome(PaymentStatus.successful);
      final out = await c.endChallengeWithPayment();
      expect(out.status, PaymentStatus.verificationFailed);
      await expectStillActive(c, PaymentStatus.verificationFailed);
    },
  );

  test(
    'no checkout opens when the payment status cannot be checked first',
    () async {
      final c = await boot(bridge, clock, payments: pay);
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      pay.succeedWith('txn_1', clock.time);
      pay.verifyThrows = true; // offline before the attempt
      final out = await c.endChallengeWithPayment();
      expect(out.status, PaymentStatus.networkError);
      expect(pay.payCalls, 0);
      expect(pay.charges, 0);
      expect(c.active, isNotNull);
    },
  );

  test(
    'verification that cannot reach the network keeps the challenge active',
    () async {
      final c = await boot(bridge, clock, payments: pay);
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      // The charge goes through, then the connection drops before the
      // result can be confirmed.
      pay.succeedWith('txn_1', clock.time);
      final charge = pay.onPay!;
      pay.onPay = (r) {
        final result = charge(r);
        pay.verifyThrows = true;
        return result;
      };
      final out = await c.endChallengeWithPayment();
      expect(out.status, PaymentStatus.networkError);
      await expectStillActive(c, PaymentStatus.networkError);

      // Network is back: the retry only verifies, it does not charge again.
      pay.verifyThrows = false;
      final retry = await c.endChallengeWithPayment();
      expect(retry.status, PaymentStatus.successful);
      expect(pay.payCalls, 1);
      expect(pay.charges, 1);
      expect(c.active, isNull);
    },
  );

  test(
    'payment succeeded but the app was closed: reconciled after restart',
    () async {
      final first = await boot(bridge, clock, payments: pay);
      await first.startInstagram();
      final id = first.active!.id;
      clock.advance(const Duration(hours: 1));
      // The app only ever saw "pending"...
      pay.onPay = (_) => const PaymentOutcome(PaymentStatus.pending);
      await first.endChallengeWithPayment();
      expect(saved()['payment']['status'], 'PENDING');
      // ...but the charge went through on the server while the app was closed.
      pay.server['commit-$id'] = PaymentOutcome(
        PaymentStatus.successful,
        transactionId: 'txn_late',
        paidAt: clock.time,
      );

      clock.advance(const Duration(minutes: 3));
      final second = await boot(bridge, clock, payments: pay);
      await second.reconcilePayment();
      expect(second.active, isNull);
      expect(second.byId(id)!.status, CommitmentStatus.endedEarly);
      expect(second.byId(id)!.payment!.transactionId, 'txn_late');
      expect(pay.payCalls, 1, reason: 'never charged a second time');
    },
  );

  test('checking a pending payment never opens a second checkout', () async {
    final c = await boot(bridge, clock, payments: pay);
    await c.startInstagram();
    clock.advance(const Duration(hours: 1));
    pay.onPay = (_) => const PaymentOutcome(PaymentStatus.pending);
    await c.endChallengeWithPayment();
    // Backend still knows nothing about it.
    final checked = await c.endChallengeWithPayment();
    expect(checked.status, PaymentStatus.notStarted);
    expect(pay.payCalls, 1);
    expect(c.active, isNotNull);
    // Only now, as a deliberate new attempt, is the checkout opened again.
    await c.endChallengeWithPayment();
    expect(pay.payCalls, 2);
  });

  test('"initiated" is saved before the provider is opened', () async {
    final c = await boot(bridge, clock, payments: pay);
    await c.startInstagram();
    clock.advance(const Duration(hours: 1));
    String? statusDuringCheckout;
    pay.onPay = (_) {
      statusDuringCheckout = saved()['payment']['status'] as String;
      return const PaymentOutcome(PaymentStatus.cancelled);
    };
    await c.endChallengeWithPayment();
    expect(statusDuringCheckout, 'INITIATED');
  });

  test('pressing pay repeatedly starts only one payment', () async {
    final c = await boot(bridge, clock, payments: pay);
    await c.startInstagram();
    clock.advance(const Duration(hours: 1));
    pay.succeedWith('txn_1', clock.time);
    final first = c.endChallengeWithPayment();
    await expectLater(
      c.endChallengeWithPayment(),
      refused(CommitmentError.paymentInProgress),
    );
    await first;
    expect(pay.payCalls, 1);
    expect(pay.charges, 1);
    // And once ended, there is nothing left to pay for.
    await expectLater(
      c.endChallengeWithPayment(),
      refused(CommitmentError.noActiveCommitment),
    );
    expect(pay.charges, 1);
  });

  test(
    'after a cancelled payment the user can try again with the same reference',
    () async {
      final c = await boot(bridge, clock, payments: pay);
      await c.startInstagram();
      final ref = 'commit-${c.active!.id}';
      clock.advance(const Duration(hours: 1));
      final refs = <String>[];
      pay.onPay = (r) {
        refs.add(r.reference);
        return const PaymentOutcome(PaymentStatus.cancelled);
      };
      await c.endChallengeWithPayment();
      pay.succeedWith('txn_2', clock.time);
      final inner = pay.onPay!;
      pay.onPay = (r) {
        refs.add(r.reference);
        return inner(r);
      };
      await c.endChallengeWithPayment();
      expect(refs, [ref, ref]);
      expect(c.active, isNull);
      expect(pay.charges, 1);
    },
  );

  test(
    'challenge that expires while payment is processing completes normally',
    () async {
      final c = await boot(bridge, clock, payments: pay);
      await c.startInstagram(minutes: 30);
      final id = c.active!.id;
      clock.advance(const Duration(minutes: 10));
      pay.onPay = (r) {
        // The user sits in the checkout until after the scheduled end.
        clock.advance(const Duration(minutes: 25));
        pay.server[r.reference] = PaymentOutcome(
          PaymentStatus.successful,
          transactionId: 'txn_slow',
          paidAt: clock.time,
        );
        return pay.server[r.reference]!;
      };
      await c.endChallengeWithPayment();
      c.tick();
      final done = c.byId(id)!;
      expect(done.isLive, isFalse);
      // The verified payment is kept on record either way and never repeated.
      expect(done.payment!.status, PaymentStatus.successful);
      expect(done.payment!.transactionId, 'txn_slow');
      expect(pay.payCalls, 1);
    },
  );

  test('ending early is not offered in the final minute', () async {
    final c = await boot(bridge, clock, payments: pay);
    await c.startInstagram(minutes: 2);
    clock.advance(const Duration(seconds: 70));
    expect(CommitmentEngine.canEndEarly(c.active!, c.now), isFalse);
    pay.succeedWith('txn', clock.time);
    await expectLater(
      c.endChallengeWithPayment(),
      refused(CommitmentError.endingSoon),
    );
    expect(pay.payCalls, 0);
    expect(c.active!.payment, isNull);
  });

  test('emergency access never charges the Commitment Amount', () async {
    final c = await boot(bridge, clock, payments: pay);
    await c.startInstagram(amount: 100, emergencyLimit: 1);
    clock.advance(const Duration(hours: 1));
    await c.startEmergency();
    clock.advance(const Duration(minutes: 5));
    c.tick();
    expect(pay.payCalls, 0);
    expect(c.active!.payment, isNull);
    expect(c.active!.emergencyRemaining, 0);
    // With no emergency access left, ending early is still possible.
    expect(CommitmentEngine.canEndEarly(c.active!, c.now), isTrue);
    await expectLater(
      c.startEmergency(),
      refused(CommitmentError.noEmergencyLeft),
    );
  });

  test('completing a challenge never charges anything', () async {
    final c = await boot(bridge, clock, payments: pay);
    await c.startInstagram(minutes: 60, amount: 500);
    clock.advance(const Duration(hours: 1));
    c.tick();
    final done = c.pendingCompletion!;
    expect(done.status, CommitmentStatus.completed);
    expect(done.payment, isNull);
    expect(pay.payCalls, 0);
    expect(pay.verifyCalls, 0);
  });

  test(
    'without a payment provider nothing is charged and nothing ends',
    () async {
      final c = await boot(bridge, clock); // real default: no provider
      expect(c.payments.isConfigured, isFalse);
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      final out = await c.endChallengeWithPayment();
      expect(out.status, PaymentStatus.failed);
      expect(out.message, UnconfiguredPaymentService.message);
      await expectStillActive(c, PaymentStatus.failed);
    },
  );

  test('payment record round trip stores no credentials', () {
    final r = PaymentRecord(
      reference: 'commit-1',
      amountRupees: 100,
      status: PaymentStatus.successful,
      initiatedAt: DateTime(2026, 10, 4, 10),
      transactionId: 'txn',
      paidAt: DateTime(2026, 10, 4, 10, 1),
    );
    final json = r.toJson();
    expect(json.keys.toSet(), {
      'reference',
      'amountRupees',
      'status',
      'initiatedAt',
      'transactionId',
      'paidAt',
      'updatedAt',
      'idempotencyKey',
      'attempt',
      'expiresAt',
      'authoritative',
      'refund',
      'refundedAt',
    });
    expect(PaymentRecord.fromJson(json).toJson(), json);
    expect(PaymentStatus.values.map((s) => s.wire), [
      'NOT_STARTED',
      'INITIATED',
      'PENDING',
      'SUCCESSFUL',
      'FAILED',
      'CANCELLED',
      'VERIFICATION_FAILED',
      'NETWORK_ERROR',
    ]);
  });
}
