import 'dart:convert';

import 'package:app/core/commitment.dart';
import 'package:app/core/commitment_engine.dart';
import 'package:app/core/payment.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeBridge bridge;
  late FakeClock clock;

  setUp(() {
    withDormantPayments();
    bridge = FakeBridge();
    clock = FakeClock();
  });

  Map saved() =>
      ((jsonDecode(bridge.disk!) as Map)['commitments'] as List).single as Map;

  void native(String type) => bridge.nativeEvents.add({
    'type': type,
    'at': clock.time.millisecondsSinceEpoch,
  });

  test(
    'everything about an active challenge survives an app restart',
    () async {
      final pay = FakePayments();
      final first = await boot(bridge, clock, payments: pay);
      await first.createCommitment(
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
      final before = first.active!;
      clock.advance(const Duration(hours: 1));
      await first.startEmergency();
      clock.advance(const Duration(minutes: 6));
      first.tick();
      pay.onPay = (_) => const PaymentOutcome(PaymentStatus.pending);
      await first.endChallengeWithPayment();

      // "Restart": a brand-new controller reading the same storage.
      clock.advance(const Duration(hours: 2));
      final second = await boot(bridge, clock, payments: FakePayments());
      final a = second.active!;
      expect(a.id, before.id);
      expect(a.packageNames, [instagram, youtube]);
      expect(a.startTime, before.startTime);
      expect(a.endTime, before.endTime, reason: 'original end time');
      expect(a.emergencyLimit, 2);
      expect(a.emergencyRemaining, 1);
      expect(a.emergencyMinutes, 5);
      expect(a.commitmentAmount, 100);
      expect(a.payment!.status, PaymentStatus.pending);
      expect(a.payment!.reference, 'commit-${before.id}');
      expect(CommitmentEngine.isBlocking(a, second.now), isTrue);
      expect(
        CommitmentEngine.remaining(a, second.now),
        const Duration(hours: 20, minutes: 54),
      );
    },
  );

  test('restarting the app cannot reset or shorten a challenge', () async {
    final first = await boot(bridge, clock);
    await first.startInstagram(minutes: 1440);
    final end = first.active!.endTime;
    for (var i = 0; i < 5; i++) {
      clock.advance(const Duration(minutes: 7));
      final again = await boot(bridge, clock);
      expect(again.active!.endTime, end);
      await expectLater(
        again.startInstagram(minutes: 2),
        throwsA(isA<CommitmentException>()),
      );
    }
  });

  test(
    'losing all permissions is recorded and shown as PROTECTION_INTERRUPTED',
    () async {
      final c = await boot(bridge, clock);
      await c.startInstagram();
      expect(c.activeState, ChallengeState.active);

      clock.advance(const Duration(hours: 1));
      bridge.accessibility = false;
      bridge.usage = false;
      await c.onResume();
      expect(c.activeState, ChallengeState.protectionInterrupted);
      expect(
        c.active!.status,
        CommitmentStatus.active,
        reason: 'still running',
      );
      expect(c.active!.interruptionCount, 1);
      expect(c.active!.payment, isNull, reason: 'never charged for this');
      expect(saved()['status'], 'ACTIVE');
      expect(
        (saved()['integrityEvents'] as List).single['type'],
        'protectionLost',
      );

      // Checking again does not record it twice.
      await c.onResume();
      expect(c.active!.interruptionCount, 1);

      clock.advance(const Duration(minutes: 20));
      bridge.accessibility = true;
      await c.onResume();
      expect(c.activeState, ChallengeState.active);
      expect(c.active!.hasOpenGap, isFalse);
      expect(
        CommitmentEngine.interruptedTime(c.active!, c.now),
        const Duration(minutes: 20),
      );
      expect(
        c.active!.endTime,
        c.active!.startTime.add(const Duration(days: 1)),
      );
    },
  );

  test(
    'Accessibility off with the backup still on is logged, not "lost"',
    () async {
      final c = await boot(bridge, clock);
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      bridge.accessibility = false;
      native(IntegrityEvent.accessibilityOff);
      await c.onResume();
      expect(c.activeState, ChallengeState.active);
      expect(c.protectionEnabled, isTrue);
      expect(c.active!.integrityEvents.single.type, 'accessibilityOff');
      expect(c.active!.interruptionCount, 0);
    },
  );

  test('a force stop is recorded when the app is next opened', () async {
    final first = await boot(bridge, clock);
    await first.startInstagram();
    clock.advance(const Duration(hours: 2));
    native(IntegrityEvent.forceStopped); // read back from Android afterwards
    bridge.accessibility = false; // force stop switches Accessibility off
    clock.advance(const Duration(minutes: 45));

    final second = await boot(bridge, clock);
    final a = second.active!;
    expect(a.status, CommitmentStatus.active, reason: 'not ended, not paid');
    expect(a.payment, isNull);
    expect(a.endTime, a.startTime.add(const Duration(days: 1)));
    expect(a.integrityEvents.map((e) => e.type), [
      'forceStopped',
      'protectionRestored', // the backup detector is working again
    ]);
    expect(a.interruptionCount, 1);
    expect(
      CommitmentEngine.interruptedTime(a, second.now),
      const Duration(minutes: 45),
    );
    expect(second.protectionLabel, 'Backup only (primary off)');
  });

  test(
    'a challenge that ran out while force-stopped is not counted as kept',
    () async {
      final first = await boot(bridge, clock);
      await first.startInstagram(minutes: 60);
      final id = first.active!.id;
      clock.advance(const Duration(minutes: 10));
      native(IntegrityEvent.forceStopped);
      clock.advance(const Duration(hours: 5)); // app never reopened in time

      final second = await boot(bridge, clock);
      final done = second.byId(id)!;
      expect(done.status, CommitmentStatus.completed);
      expect(done.payment, isNull, reason: 'inactivity never charges');
      expect(done.interruptionCount, 1);
      expect(CommitmentEngine.keptCleanly(done), isFalse);
      expect(
        CommitmentEngine.interruptedTime(done, second.now),
        const Duration(minutes: 50),
      );
      expect(second.stats.completed, 0);
      expect(second.stats.interrupted, 1);
      expect(second.stats.completionRate, 0);
    },
  );

  // Tamper protection was removed in 2.9.0. A record written by an older
  // version is still read without harm.
  test('an old tamper-protection record is kept and changes nothing', () async {
    final c = await boot(bridge, clock);
    await c.startInstagram();
    clock.advance(const Duration(hours: 1));
    native(IntegrityEvent.tamperProtectionOff);
    await c.onResume();
    expect(c.active!.integrityEvents.single.type, 'tamperProtectionOff');
    expect(c.active!.interruptionCount, 0);
    expect(c.activeState, ChallengeState.active, reason: 'still blocking');
  });

  test('events outside any challenge are ignored', () async {
    final c = await boot(bridge, clock);
    native(IntegrityEvent.forceStopped);
    await c.onResume();
    await c.startInstagram();
    expect(c.active!.integrityEvents, isEmpty);
  });

  test('phone restart, crash or being offline changes nothing', () async {
    final first = await boot(bridge, clock);
    await first.startInstagram(emergencyLimit: 2);
    final snapshot = jsonEncode(first.active!.toJson());
    clock.advance(const Duration(minutes: 30));
    // No events, permissions intact: just a fresh process.
    final second = await boot(bridge, clock);
    expect(jsonEncode(second.active!.toJson()), snapshot);
    expect(second.activeState, ChallengeState.active);
  });

  test('explicit states', () async {
    final pay = FakePayments();
    final c = await boot(bridge, clock, payments: pay);
    expect(ChallengeState.values.map((s) => s.wire), [
      'ACTIVE',
      'EMERGENCY',
      'PROTECTION_INTERRUPTED',
      'PAYMENT_PENDING',
      'PAYMENT_VERIFIED',
      'ENDED_EARLY',
      'COMPLETED',
      'CANCELLED',
    ]);
    await c.startInstagram(emergencyLimit: 1);
    final id = c.active!.id;
    expect(c.activeState, ChallengeState.active);
    clock.advance(const Duration(hours: 1));
    await c.startEmergency();
    expect(c.activeState, ChallengeState.emergency);
    clock.advance(const Duration(minutes: 5));
    c.tick();
    pay.onPay = (_) => const PaymentOutcome(PaymentStatus.pending);
    await c.endChallengeWithPayment();
    expect(c.activeState, ChallengeState.paymentPending);
    expect(c.active, isNotNull, reason: 'pending payment does not unlock');
    pay.server['commit-$id'] = PaymentOutcome(
      PaymentStatus.successful,
      transactionId: 't',
      paidAt: clock.time,
    );
    await c.endChallengeWithPayment();
    expect(c.activeState, isNull);
    expect(
      CommitmentEngine.stateOf(c.byId(id)!, c.now),
      ChallengeState.endedEarly,
    );
  });

  // Changed in 2.9.0: nothing that prevents uninstalling is required.
  test('a challenge can start with blocking alone', () async {
    final c = await boot(bridge, clock);
    expect(c.protectionEnabled, isTrue);
    expect(c.readyToStart, isTrue);
    await c.startInstagram();
    expect(c.active, isNotNull);
  });
}
