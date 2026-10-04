import 'dart:convert';

import 'package:app/core/commitment.dart';
import 'package:app/core/commitment_engine.dart';
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

  Matcher refused(CommitmentError e) =>
      throwsA(isA<CommitmentException>().having((x) => x.error, 'error', e));

  List savedCommitments() =>
      (jsonDecode(bridge.disk!) as Map)['commitments'] as List;

  test('creating a commitment stores it and makes it active', () async {
    final c = await boot(bridge, clock);
    expect(c.active, isNull);
    await c.startInstagram(amount: 500);
    expect(c.active!.appNames, ['Instagram']);
    expect(c.active!.commitmentAmount, 500);
    expect(c.active!.endTime, clock.time.add(const Duration(hours: 24)));
    expect(savedCommitments().single['status'], 'ACTIVE');
    expect(savedCommitments().single['packageNames'], [instagram]);
  });

  test('one commitment blocks several apps', () async {
    final c = await boot(bridge, clock);
    await c.createCommitment(
      consentAccepted: true,
      apps: const [AppRef(instagram, 'Instagram'), AppRef(youtube, 'YouTube')],
      durationMinutes: 10080,
      amount: 100,
      emergencyLimit: 2,
    );
    expect(c.active!.appNames, ['Instagram', 'YouTube']);
    expect(c.active!.endTime, clock.time.add(const Duration(days: 7)));
    expect(savedCommitments().single['packageNames'], [instagram, youtube]);
    expect(savedCommitments().single['appNames'], ['Instagram', 'YouTube']);

    final again = await boot(bridge, clock);
    expect(again.active!.packageNames, [instagram, youtube]);
  });

  test('a commitment needs at least one app', () async {
    final c = await boot(bridge, clock);
    await expectLater(
      c.createCommitment(
        consentAccepted: true,
        apps: const [],
        durationMinutes: 60,
        amount: 100,
      ),
      refused(CommitmentError.noApps),
    );
  });

  test('only one active commitment is allowed', () async {
    final c = await boot(bridge, clock);
    await c.startInstagram();
    await expectLater(
      c.createCommitment(
        consentAccepted: true,
        apps: const [AppRef(youtube, 'YouTube')],
        durationMinutes: 60,
        amount: 100,
      ),
      refused(CommitmentError.duplicateActive),
    );
    // ...also not during emergency access.
    await c.startEmergency();
    await expectLater(
      c.startInstagram(),
      refused(CommitmentError.duplicateActive),
    );
    expect(c.history, hasLength(1));
  });

  test('Commit itself and system apps cannot be selected', () async {
    final c = await boot(bridge, clock);
    await expectLater(
      c.createCommitment(
        consentAccepted: true,
        apps: const [
          AppRef(instagram, 'Instagram'),
          AppRef('com.commit.app', 'Commit'),
        ],
        durationMinutes: 60,
        amount: 100,
      ),
      refused(CommitmentError.invalidApp),
    );
    expect(c.active, isNull);
  });

  test(
    'commitment survives an app restart with the correct remaining time',
    () async {
      final first = await boot(bridge, clock);
      await first.startInstagram();
      final end = first.active!.endTime;

      clock.advance(const Duration(hours: 5, minutes: 18));
      final second = await boot(bridge, clock); // new process, same storage
      expect(second.active, isNotNull);
      expect(second.active!.endTime, end);
      expect(
        CommitmentEngine.remaining(second.active!, second.now),
        const Duration(hours: 18, minutes: 42),
      );
    },
  );

  test('a short 2-minute commitment completes on time', () async {
    final c = await boot(bridge, clock);
    await c.startInstagram(minutes: 2);
    clock.advance(const Duration(minutes: 1, seconds: 59));
    c.tick();
    expect(c.active, isNotNull);
    clock.advance(const Duration(seconds: 1));
    c.tick();
    expect(c.active, isNull);
    expect(c.pendingCompletion, isNotNull);
  });

  test(
    'commitment that expired while the app was closed is completed',
    () async {
      final first = await boot(bridge, clock);
      await first.startInstagram(minutes: 60);
      clock.advance(const Duration(hours: 3));

      final second = await boot(bridge, clock);
      expect(second.active, isNull);
      final done = second.pendingCompletion!;
      expect(done.status, CommitmentStatus.completed);
      expect(done.completedAt, done.endTime);

      await second.acknowledgeCompletion(done.id);
      expect(second.pendingCompletion, isNull);
      final third = await boot(bridge, clock);
      expect(third.pendingCompletion, isNull);
      expect(third.history.single.status, CommitmentStatus.completed);
    },
  );

  test(
    'emergency access: limited uses, expiry, automatic return to ACTIVE',
    () async {
      final c = await boot(bridge, clock);
      await c.startInstagram(emergencyLimit: 2, emergencyMinutes: 5);
      final end = c.active!.endTime;
      clock.advance(const Duration(hours: 5));

      await c.startEmergency();
      expect(c.active!.status, CommitmentStatus.emergency);
      expect(c.active!.emergencyRemaining, 1);
      expect(c.active!.endTime, end);
      expect(CommitmentEngine.isBlocking(c.active!, c.now), isFalse);

      await expectLater(
        c.startEmergency(),
        refused(CommitmentError.emergencyAlreadyActive),
      );
      expect(c.active!.emergencyRemaining, 1);

      clock.advance(const Duration(minutes: 5));
      c.tick();
      expect(c.active!.status, CommitmentStatus.active);
      expect(c.relockNotice, isTrue);
      expect(CommitmentEngine.isBlocking(c.active!, c.now), isTrue);
      expect(c.active!.endTime, end);

      await c.startEmergency();
      expect(c.active!.emergencyRemaining, 0);
      expect(c.relockNotice, isFalse);
      clock.advance(const Duration(minutes: 5));
      c.tick();

      // All uses consumed: no more until the commitment ends.
      await expectLater(
        c.startEmergency(),
        refused(CommitmentError.noEmergencyLeft),
      );
      expect(c.active!.status, CommitmentStatus.active);

      final again = await boot(bridge, clock);
      expect(again.active!.emergencyRemaining, 0);
    },
  );

  test('a commitment with no emergency access cannot be unlocked', () async {
    final c = await boot(bridge, clock);
    await c.startInstagram(emergencyLimit: 0);
    await expectLater(
      c.startEmergency(),
      refused(CommitmentError.noEmergencyLeft),
    );
  });

  test('emergency still running after a restart is restored', () async {
    final first = await boot(bridge, clock);
    await first.startInstagram(emergencyMinutes: 30);
    await first.startEmergency();
    clock.advance(const Duration(minutes: 10));

    final second = await boot(bridge, clock);
    expect(second.active!.status, CommitmentStatus.emergency);
    expect(
      CommitmentEngine.emergencyRemaining(second.active!, second.now),
      const Duration(minutes: 20),
    );
    expect(second.relockNotice, isFalse);
  });

  test('emergency that expired during a restart re-locks', () async {
    final first = await boot(bridge, clock);
    await first.startInstagram(emergencyMinutes: 30);
    await first.startEmergency();
    clock.advance(const Duration(hours: 2));

    final second = await boot(bridge, clock);
    expect(second.active!.status, CommitmentStatus.active);
    expect(second.relockNotice, isTrue);
    expect(CommitmentEngine.isBlocking(second.active!, second.now), isTrue);
    expect(savedCommitments().single['status'], 'ACTIVE');
  });

  test('commitment that ended during emergency access completes', () async {
    final c = await boot(bridge, clock);
    await c.startInstagram(minutes: 30, emergencyMinutes: 30);
    clock.advance(const Duration(minutes: 20));
    await c.startEmergency();
    clock.advance(const Duration(minutes: 11));
    c.tick();
    expect(c.active, isNull);
    expect(c.pendingCompletion!.emergencyAccessCount, 1);
  });

  test('emergency access needs an active commitment', () async {
    final c = await boot(bridge, clock);
    await expectLater(
      c.startEmergency(),
      refused(CommitmentError.noActiveCommitment),
    );
  });

  test('history, newest first, and statistics', () async {
    final c = await boot(bridge, clock);
    await c.startInstagram(minutes: 60, amount: 100);
    await c.startEmergency();
    clock.advance(const Duration(hours: 2));
    c.tick();
    await c.createCommitment(
      consentAccepted: true,
      apps: const [AppRef(youtube, 'YouTube')],
      durationMinutes: 240,
      amount: 100,
    );

    expect(c.history.map((x) => x.appNames.first), ['YouTube', 'Instagram']);
    expect(c.stats.total, 2);
    expect(c.stats.completed, 1);
    expect(c.stats.emergencyUses, 1);
    expect(c.stats.completionRate, 50);
  });

  test('reset deletes history but keeps the active commitment', () async {
    final c = await boot(bridge, clock);
    await c.startInstagram(minutes: 60);
    clock.advance(const Duration(hours: 2));
    c.tick();
    await c.startInstagram();
    await c.resetData();
    expect(c.history, hasLength(1));
    expect(c.active, isNotNull);
    expect((await boot(bridge, clock)).active, isNotNull);
  });

  test('data saved by version 1.x loads and keeps blocking', () async {
    final start = clock.time.millisecondsSinceEpoch;
    bridge.disk = jsonEncode({
      'version': 1,
      'onboarded': true,
      'commitments': [
        {
          'id': 'old',
          'packageName': instagram,
          'appName': 'Instagram',
          'startTime': start,
          'endTime': start + 24 * 3600 * 1000,
          'durationMinutes': 1440,
          'commitmentAmount': 500,
          'status': 'ACTIVE',
          'emergencyAccessCount': 0,
          'createdAt': start,
          'completedAt': null,
          'lastEmergencyStart': null,
          'lastEmergencyEnd': null,
          'completionAcknowledged': false,
        },
      ],
    });
    final c = await boot(bridge, clock);
    expect(c.onboarded, isTrue);
    expect(c.loadWarning, isNull);
    expect(c.active!.appNames, ['Instagram']);
    expect(CommitmentEngine.isBlocking(c.active!, c.now), isTrue);
  });

  test('invalid saved records are skipped and reported', () async {
    final c = await boot(bridge, clock);
    await c.startInstagram();
    final doc = jsonDecode(bridge.disk!) as Map<String, dynamic>;
    (doc['commitments'] as List).add({'id': 'broken', 'status': 'ACTIVE'});
    bridge.disk = jsonEncode(doc);

    final again = await boot(bridge, clock);
    expect(again.history, hasLength(1));
    expect(again.active!.appNames, ['Instagram']);
    expect(again.loadWarning, isNotNull);
  });

  test('completely corrupt storage does not crash', () async {
    bridge.disk = '{not json';
    final c = await boot(bridge, clock);
    expect(c.loaded, isTrue);
    expect(c.history, isEmpty);
    expect(c.loadWarning, isNotNull);
  });

  test('multiple active commitments on disk are reduced to one', () async {
    final c = await boot(bridge, clock);
    await c.startInstagram();
    final doc = jsonDecode(bridge.disk!) as Map<String, dynamic>;
    final list = doc['commitments'] as List;
    list.add({
      ...(list.first as Map<String, dynamic>),
      'id': 'second',
      'createdAt': (list.first as Map)['createdAt'] + 1000,
    });
    bridge.disk = jsonEncode(doc);

    final again = await boot(bridge, clock);
    expect(again.history.where((x) => x.isLive), hasLength(1));
    expect(again.active!.id, isNot('second'));
    expect(again.byId('second')!.status, CommitmentStatus.cancelled);
    expect(again.loadWarning, isNotNull);
  });

  test('disabled protection and uninstalled apps are detected', () async {
    final c = await boot(bridge, clock);
    await c.startInstagram();
    expect(c.protectionEnabled, isTrue);
    expect(c.fullProtection, isTrue);
    // One detector off: still protected, but no longer full protection.
    bridge.accessibility = false;
    await c.onResume();
    expect(c.protectionEnabled, isTrue);
    expect(c.fullProtection, isFalse);
    expect(c.protectionLabel, 'Backup only (primary off)');
    bridge.overlay = false;
    bridge.uninstalled.add(instagram);
    await c.onResume();
    expect(c.protectionEnabled, isFalse);
    expect(c.missingApps, ['Instagram']);
    expect(c.active, isNotNull, reason: 'the commitment itself continues');
  });

  test('onboarding flag persists', () async {
    final c = await boot(bridge, clock);
    expect(c.onboarded, isFalse);
    await c.completeOnboarding();
    expect((await boot(bridge, clock)).onboarded, isTrue);
  });
}
