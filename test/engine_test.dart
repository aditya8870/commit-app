import 'package:app/core/commitment.dart';
import 'package:app/core/commitment_engine.dart';
import 'package:app/ui/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 10, 3, 10);
  const insta = AppRef('com.instagram.android', 'Instagram');
  const yt = AppRef('com.google.android.youtube', 'YouTube');
  const fb = AppRef('com.facebook.katana', 'Facebook');

  Commitment make({
    List<AppRef> apps = const [insta],
    int minutes = 1440,
    int amount = 100,
    int limit = 2,
    int emergencyMinutes = 5,
  }) => CommitmentEngine.create(
    id: 'c1',
    apps: apps,
    durationMinutes: minutes,
    amount: amount,
    emergencyLimit: limit,
    emergencyMinutes: emergencyMinutes,
    now: t0,
  );

  Matcher refused(CommitmentError e) =>
      throwsA(isA<CommitmentException>().having((x) => x.error, 'error', e));

  group('Commitment model', () {
    test('creation sets timestamps, apps and ACTIVE status', () {
      final c = make(apps: const [insta, yt, fb], minutes: 10080, amount: 500);
      expect(c.status, CommitmentStatus.active);
      expect(c.startTime, t0);
      expect(c.endTime, t0.add(const Duration(days: 7)));
      expect(c.appNames, ['Instagram', 'YouTube', 'Facebook']);
      expect(c.commitmentAmount, 500);
      expect(c.emergencyLimit, 2);
      expect(c.emergencyRemaining, 2);
      expect(c.emergencyAccessCount, 0);
    });

    test('JSON round trip keeps every field, including all apps', () {
      final c = CommitmentEngine.startEmergency(
        make(apps: const [insta, yt]),
        t0.add(const Duration(hours: 5)),
      );
      final back = Commitment.fromJson(c.toJson());
      expect(back.toJson(), c.toJson());
      expect(back.packageNames, c.packageNames);
      expect(back.status, CommitmentStatus.emergency);
      expect(back.emergencyRemaining, 1);
    });

    test('records saved before 2.0 (single app) still load', () {
      final old = {
        'id': 'old',
        'packageName': 'com.instagram.android',
        'appName': 'Instagram',
        'startTime': t0.millisecondsSinceEpoch,
        'endTime': t0.add(const Duration(hours: 24)).millisecondsSinceEpoch,
        'durationMinutes': 1440,
        'commitmentAmount': 500,
        'status': 'ACTIVE',
        'emergencyAccessCount': 1,
        'createdAt': t0.millisecondsSinceEpoch,
      };
      final c = Commitment.fromJson(old);
      expect(c.appNames, ['Instagram']);
      expect(c.emergencyLimit, 3);
      expect(c.emergencyMinutes, 5);
      expect(c.emergencyRemaining, 2);
    });

    test('invalid saved records are rejected', () {
      final good = make().toJson();
      expect(
        () => Commitment.fromJson({...good, 'status': 'WHATEVER'}),
        throwsFormatException,
      );
      expect(
        () => Commitment.fromJson({...good, 'packageNames': <String>[]}),
        throwsFormatException,
      );
      expect(
        () => Commitment.fromJson({...good, 'appNames': <String>[]}),
        throwsFormatException,
      );
      expect(
        () => Commitment.fromJson({...good, 'endTime': good['startTime']}),
        throwsFormatException,
      );
      expect(
        () => Commitment.fromJson({...good}..remove('id')),
        throwsFormatException,
      );
      expect(
        () => Commitment.fromJson({...good, 'lastEmergencyStart': 5}),
        throwsFormatException,
      );
    });

    test(
      'flexible durations: every preset and custom values up to 30 days',
      () {
        expect(CommitmentEngine.shortDurations, [2, 5, 10, 15, 30]);
        expect(CommitmentEngine.hourDurations, [60, 120, 180, 360, 720]);
        expect(CommitmentEngine.dayDurations, [
          1440,
          2880,
          4320,
          10080,
          20160,
          43200,
        ]);
        for (final m in [
          ...CommitmentEngine.shortDurations,
          ...CommitmentEngine.hourDurations,
          ...CommitmentEngine.dayDurations,
          1, 7, 45, 1500, // custom
        ]) {
          expect(make(minutes: m).endTime, t0.add(Duration(minutes: m)));
        }
        expect(
          () => make(minutes: 0),
          refused(CommitmentError.invalidDuration),
        );
        expect(
          () => make(minutes: 43201),
          refused(CommitmentError.invalidDuration),
        );
      },
    );

    test('validation of apps, amount and emergency settings', () {
      expect(() => make(apps: const []), refused(CommitmentError.noApps));
      expect(
        () => make(apps: const [insta, insta]),
        refused(CommitmentError.invalidApp),
      );
      expect(CommitmentEngine.amounts, [100, 500, 1000, 2500, 5000, 10000]);
      expect(CommitmentEngine.minAmount, 100);
      expect(CommitmentEngine.maxAmount, 10000);
      for (final a in [...CommitmentEngine.amounts, 100, 275, 9999, 10000]) {
        expect(make(amount: a).commitmentAmount, a);
      }
      // 0 = a challenge with no financial commitment (2.9.0).
      expect(make(amount: 0).commitmentAmount, 0);
      for (final bad in [1, 10, 50, 99, 10001, 50000, -5]) {
        expect(() => make(amount: bad), refused(CommitmentError.invalidAmount));
      }
      expect(CommitmentEngine.emergencyLimits, [0, 1, 2, 3]);
      expect(
        () => make(limit: 4),
        refused(CommitmentError.invalidEmergencyLimit),
      );
      expect(CommitmentEngine.emergencyDurationsMinutes, [2, 5, 10, 15, 30]);
      expect(
        () => make(emergencyMinutes: 60),
        refused(CommitmentError.invalidEmergencyDuration),
      );
    });
  });

  group('Time rules', () {
    test('remaining time comes from the end timestamp', () {
      final c = make();
      expect(
        CommitmentEngine.remaining(
          c,
          t0.add(const Duration(hours: 5, minutes: 18)),
        ),
        const Duration(hours: 18, minutes: 42),
      );
      expect(
        CommitmentEngine.remaining(c, t0.add(const Duration(days: 3))),
        Duration.zero,
      );
    });

    test('completion is detected exactly at endTime', () {
      final c = make(minutes: 30);
      final before = t0.add(const Duration(minutes: 29, seconds: 59));
      expect(CommitmentEngine.isBlocking(c, before), isTrue);
      final done = CommitmentEngine.resolve(
        c,
        t0.add(const Duration(minutes: 30)),
      );
      expect(done.status, CommitmentStatus.completed);
      expect(done.completedAt, c.endTime);
      expect(
        CommitmentEngine.isBlocking(c, t0.add(const Duration(hours: 1))),
        isFalse,
      );
    });

    test('emergency window uses the duration chosen at creation', () {
      final at = t0.add(const Duration(hours: 5));
      for (final m in CommitmentEngine.emergencyDurationsMinutes) {
        final e = CommitmentEngine.startEmergency(
          make(emergencyMinutes: m),
          at,
        );
        expect(e.lastEmergencyStart, at);
        expect(e.lastEmergencyEnd, at.add(Duration(minutes: m)));
        expect(e.status, CommitmentStatus.emergency);
        expect(e.emergencyAccessCount, 1);
      }
    });

    test('emergency access never changes the original end time', () {
      final c = make();
      final e = CommitmentEngine.startEmergency(
        c,
        t0.add(const Duration(hours: 5)),
      );
      expect(e.endTime, c.endTime);
      expect(e.startTime, c.startTime);
    });

    test('emergency access unblocks, then re-locks automatically', () {
      final at = t0.add(const Duration(hours: 5));
      final e = CommitmentEngine.startEmergency(make(), at);
      expect(CommitmentEngine.isBlocking(e, at), isFalse);
      expect(
        CommitmentEngine.emergencyRemaining(
          e,
          at.add(const Duration(seconds: 28)),
        ),
        const Duration(minutes: 4, seconds: 32),
      );
      final after = at.add(const Duration(minutes: 5));
      expect(CommitmentEngine.isBlocking(e, after), isTrue);
      expect(
        CommitmentEngine.resolve(e, after).status,
        CommitmentStatus.active,
      );
    });

    test('overlapping emergency sessions are refused', () {
      final at = t0.add(const Duration(hours: 1));
      final e = CommitmentEngine.startEmergency(make(), at);
      expect(
        () => CommitmentEngine.startEmergency(
          e,
          at.add(const Duration(minutes: 2)),
        ),
        refused(CommitmentError.emergencyAlreadyActive),
      );
    });

    test('emergency uses are limited to the chosen number', () {
      var c = make(limit: 2);
      var t = t0.add(const Duration(hours: 1));
      c = CommitmentEngine.startEmergency(c, t);
      expect(c.emergencyRemaining, 1);
      t = t.add(const Duration(minutes: 10));
      c = CommitmentEngine.startEmergency(c, t);
      expect(c.emergencyRemaining, 0);
      t = t.add(const Duration(minutes: 10));
      expect(
        () => CommitmentEngine.startEmergency(c, t),
        refused(CommitmentError.noEmergencyLeft),
      );
      expect(CommitmentEngine.isBlocking(c, t), isTrue);
    });

    test('no emergency access when none was chosen', () {
      expect(
        () => CommitmentEngine.startEmergency(
          make(limit: 0),
          t0.add(const Duration(hours: 1)),
        ),
        refused(CommitmentError.noEmergencyLeft),
      );
    });

    test('emergency window is clipped to the commitment end', () {
      final c = make(minutes: 30, emergencyMinutes: 30);
      final e = CommitmentEngine.startEmergency(
        c,
        t0.add(const Duration(minutes: 20)),
      );
      expect(e.lastEmergencyEnd, c.endTime);
      expect(
        CommitmentEngine.resolve(e, c.endTime).status,
        CommitmentStatus.completed,
      );
    });

    test('emergency cannot start on a finished commitment', () {
      expect(
        () => CommitmentEngine.startEmergency(
          make(minutes: 30),
          t0.add(const Duration(hours: 1)),
        ),
        refused(CommitmentError.noActiveCommitment),
      );
    });

    test('finished commitments never change again', () {
      final done = CommitmentEngine.resolve(
        make(minutes: 30),
        t0.add(const Duration(hours: 1)),
      );
      expect(identical(CommitmentEngine.resolve(done, t0), done), isTrue);
    });
  });

  group('Statistics and messages', () {
    test('completion rate is completed / total', () {
      final list = [
        for (var i = 0; i < 9; i++)
          make().copyWith(status: CommitmentStatus.completed),
        make().copyWith(emergencyAccessCount: 3),
        make().copyWith(status: CommitmentStatus.cancelled),
        make(),
      ];
      final s = CommitmentEngine.stats(list);
      expect(s.total, 12);
      expect(s.completed, 9);
      expect(s.emergencyUses, 3);
      expect(s.completionRate, 75);
      expect(CommitmentEngine.stats(const []).completionRate, 0);
    });

    test('motivational message is one of the six and stable', () {
      final c = make();
      expect(CommitmentEngine.motivationalMessages, hasLength(6));
      expect(
        CommitmentEngine.motivationalMessages,
        contains(CommitmentEngine.messageFor(c)),
      );
      expect(CommitmentEngine.messageFor(c), CommitmentEngine.messageFor(c));
    });
  });

  test('formatting', () {
    expect(formatRemaining(const Duration(days: 5, hours: 14)), '5d 14h');
    expect(formatTimeLeft(const Duration(hours: 2, minutes: 34)), '2h 34m');
    expect(formatTimeLeft(const Duration(minutes: 3, seconds: 1)), '4 min');
    expect(formatTimeLeft(const Duration(seconds: 40)), 'Under 1 min');
    expect(
      formatRemainingSentence(const Duration(days: 2, hours: 4)),
      '2 days 4 hours remaining',
    );
    expect(
      formatRemainingSentence(const Duration(hours: 2, minutes: 34)),
      '2h 34m remaining',
    );
    expect(formatRemaining(const Duration(hours: 18, minutes: 42)), '18h 42m');
    expect(formatRemaining(const Duration(minutes: 4, seconds: 5)), '4m 05s');
    expect(formatRemaining(const Duration(seconds: 9)), '9s');
    expect(formatRemaining(const Duration(seconds: -4)), '0s');
    expect(formatClock(const Duration(minutes: 4, seconds: 32)), '04:32');
    expect(formatClock(Duration.zero), '00:00');
    expect(formatAmount(1000), '₹1,000');
    expect(formatMinutes(2), '2 minutes');
    expect(formatMinutes(60), '1 hour');
    expect(formatMinutes(1440), '1 day');
    expect(formatMinutes(43200), '30 days');
    expect(formatMinutes(1500), '1 day 1 hour');
    expect(formatChip(2), '2 min');
    expect(formatChip(60), '1 hr');
    expect(formatChip(10080), '7 days');
    expect(commitmentTitle(10080), '7-Day Digital Detox');
    expect(commitmentTitle(30), '30-Minute Digital Detox');
    expect(
      appsLabel(['Instagram', 'YouTube', 'Facebook']),
      'Instagram + YouTube + Facebook',
    );
    expect(appsLabel(['A', 'B', 'C', 'D']), 'A + B + 2 more');
    expect(formatEmergencyLimit(0), 'No emergency access');
    expect(formatEmergencyLimit(2), '2 uses');
  });
}
