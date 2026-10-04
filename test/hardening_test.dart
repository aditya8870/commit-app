import 'dart:convert';
import 'dart:io';

import 'package:app/core/commitment.dart';
import 'package:app/core/payment.dart';
import 'package:app/data/commit_controller.dart';
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

  Map doc() => jsonDecode(bridge.disk!) as Map;

  group('B4: backup and restore', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();

    test('Android backup is switched off', () {
      expect(manifest, contains('android:allowBackup="false"'));
      expect(manifest, contains('android:fullBackupContent="false"'));
      expect(
        manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
      );
      final rules = File(
        'android/app/src/main/res/xml/data_extraction_rules.xml',
      ).readAsStringSync();
      for (final section in ['cloud-backup', 'device-transfer']) {
        final body = rules.split('<$section>')[1].split('</$section>')[0];
        expect(body, contains('<exclude domain="sharedpref"'));
      }
    });

    // Changed in 2.7.0 (backend Phase 4): the app now registers an anonymous
    // installation with its server, so it needs the internet. What must hold
    // instead: HTTPS only, and still no backup.
    test('internet access is HTTPS only, and backup stays off', () {
      expect(manifest, contains('android.permission.INTERNET'));
      expect(manifest, contains('android:usesCleartextTraffic="false"'));
      expect(manifest, contains('android:allowBackup="false"'));
      expect(manifest, isNot(contains('ACCESS_NETWORK_STATE')));
    });
  });

  group('B5: local reset never deletes payment history', () {
    test('paid and unresolved records survive "Reset local data"', () async {
      final c = await boot(bridge, clock, payments: pay);

      // 1: completed, never paid -> may be deleted.
      await c.startInstagram(minutes: 60);
      clock.advance(const Duration(hours: 2));
      c.tick();

      // 2: ended early with a verified payment -> must stay.
      await c.startInstagram();
      final paidId = c.active!.id;
      clock.advance(const Duration(hours: 1));
      pay.succeedWith('txn_keep', clock.time);
      await c.endChallengeWithPayment();

      // 3: completed while a payment was still pending -> must stay.
      await c.startInstagram(minutes: 60);
      final pendingId = c.active!.id;
      clock.advance(const Duration(minutes: 10));
      pay.onPay = (_) => const PaymentOutcome(PaymentStatus.pending);
      await c.endChallengeWithPayment();
      clock.advance(const Duration(hours: 2));
      c.tick();

      expect(c.history, hasLength(3));
      await c.resetData();
      expect(c.history.map((x) => x.id).toSet(), {paidId, pendingId});
      expect(c.byId(paidId)!.payment!.transactionId, 'txn_keep');

      final again = await boot(bridge, clock, payments: pay);
      expect(again.byId(paidId)!.status, CommitmentStatus.endedEarly);
      expect(again.byId(pendingId)!.payment!.status, PaymentStatus.pending);
    });
  });

  group('B8: the blocker and the checkout', () {
    test(
      'payment apps are let through only while the checkout is open',
      () async {
        final c = await boot(bridge, clock, payments: pay);
        await c.startInstagram();
        clock.advance(const Duration(hours: 1));
        expect(doc()['checkout'], isNull);

        Map? during;
        pay.onPay = (_) {
          during = doc()['checkout'] as Map?;
          return const PaymentOutcome(PaymentStatus.cancelled);
        };
        await c.endChallengeWithPayment();

        expect(during, isNotNull, reason: 'window open while checkout is open');
        expect(
          during!['until'],
          clock.time
              .add(CommitController.checkoutWindow)
              .millisecondsSinceEpoch,
        );
        expect(
          doc()['checkout'],
          isNull,
          reason: 'closed as soon as it returns',
        );
        expect(c.checkoutUntil, isNull);
      },
    );

    test('no window opens when no checkout opens', () async {
      final c = await boot(bridge, clock); // no provider
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      // The stand-in authorises, the unconfigured provider fails at once.
      await c.endChallengeWithPayment();
      expect(doc()['checkout'], isNull);
    });

    test(
      'a window left behind by a crash is cleared on the next start',
      () async {
        final c = await boot(bridge, clock, payments: pay);
        await c.startInstagram();
        final d = doc();
        d['checkout'] = {
          'until': clock.time
              .add(const Duration(minutes: 9))
              .millisecondsSinceEpoch,
        };
        bridge.disk = jsonEncode(d);
        final again = await boot(bridge, clock, payments: pay);
        expect(again.checkoutUntil, isNull);
        expect(doc()['checkout'], isNull);
      },
    );

    test('windows are limited per challenge', () async {
      final c = await boot(bridge, clock, payments: pay);
      await c.startInstagram();
      clock.advance(const Duration(hours: 1));
      final seen = <bool>[];
      pay.onPay = (_) {
        seen.add(doc()['checkout'] != null);
        return const PaymentOutcome(PaymentStatus.cancelled);
      };
      for (var i = 0; i < CommitController.maxCheckoutWindows + 2; i++) {
        await c.endChallengeWithPayment();
      }
      expect(
        seen.where((x) => x),
        hasLength(CommitController.maxCheckoutWindows),
      );
      expect(seen.last, isFalse);
      expect(c.active, isNotNull);
    });

    test('native rule exempts only payment apps', () {
      final store = File(
        'android/app/src/main/kotlin/com/commit/app/NativeStore.kt',
      ).readAsStringSync();
      expect(
        store,
        contains('if (inCheckout(now) && pkg in PaymentApps.packages(ctx))'),
      );
    });
  });

  group('migration', () {
    test(
      'data saved by 2.2.0 loads unchanged and gains the new fields',
      () async {
        final start = clock.time.millisecondsSinceEpoch;
        bridge.disk = jsonEncode({
          'version': 1,
          'onboarded': true,
          'commitments': [
            {
              'id': 'old-1',
              'packageNames': [instagram],
              'appNames': ['Instagram'],
              'startTime': start,
              'endTime': start + 86400000,
              'durationMinutes': 1440,
              'commitmentAmount': 100,
              'status': 'ACTIVE',
              'emergencyLimit': 1,
              'emergencyMinutes': 5,
              'emergencyAccessCount': 0,
              'createdAt': start,
              'payment': {
                'reference': 'commit-old-1',
                'amountRupees': 100,
                'status': 'PENDING',
                'initiatedAt': start,
              },
              'integrityEvents': [],
            },
          ],
        });
        final c = await boot(bridge, clock, payments: pay);
        expect(c.loadWarning, isNull);
        final a = c.active!;
        expect(a.id, 'old-1');
        expect(a.serverIssued, isFalse);
        expect(a.ownerUserId, isNull);
        expect(a.payment!.status, PaymentStatus.pending);
        expect(a.payment!.attempt, 0);
        expect(a.payment!.authoritative, isFalse);
        expect(c.installId, isNotEmpty);
        expect(doc()['version'], 2);
        expect(doc()['installId'], c.installId);
      },
    );
  });

  group('B10: release signing', () {
    test('build uses a release key only when one is provided', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('rootProject.file("key.properties")'));
      expect(gradle, contains('if (hasReleaseKey) "release" else "debug"'));
      expect(File('android/key.properties').existsSync(), isFalse);
      expect(File('android/key.properties.example').existsSync(), isTrue);
    });
  });
}
