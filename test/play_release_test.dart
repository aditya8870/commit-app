// Phase 6 remediation: what the first Google Play release must and must not
// do. Runs with the app's real defaults (payments off).
import 'dart:convert';
import 'dart:io';

import 'package:app/app.dart';
import 'package:app/core/commitment.dart';
import 'package:app/core/commitment_engine.dart';
import 'package:app/core/features.dart';
import 'package:app/data/commit_controller.dart';
import 'package:app/ui/screens/create_flow.dart';
import 'package:app/ui/screens/history_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'challenge_sync_test.dart' show ChallengeServer, Phone;
import 'fakes.dart';

String _read(String path) => File(path).readAsStringSync();
const _kotlin = 'android/app/src/main/kotlin/com/commit/app';

/// Every piece of text currently on screen.
String _screenText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .join('\n');

void _expectNoMoney(WidgetTester tester, String where) {
  final text = _screenText(tester);
  for (final word in [
    '₹',
    'Commitment Amount',
    'payable',
    'charged',
    'payment',
    'Payment',
    'pay ',
    'End challenge early',
    'refund',
  ]) {
    expect(text, isNot(contains(word)), reason: '"$word" on $where');
  }
}

void main() {
  late FakeBridge bridge;
  late FakeClock clock;
  late CommitController controller;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CommitApp(controller: controller));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(text).first);
    await tester.pumpAndSettle();
  }

  setUp(() async {
    bridge = FakeBridge();
    clock = FakeClock();
    controller = await boot(bridge, clock);
  });

  test('the release default has payments switched off', () {
    expect(Features.payments, isFalse);
  });

  group('tamper protection is removed', () {
    final manifest = _read('android/app/src/main/AndroidManifest.xml');

    test('no device-admin component, so normal uninstall stays possible', () {
      expect(manifest, isNot(contains('BIND_DEVICE_ADMIN')));
      expect(manifest, isNot(contains('device_admin')));
      expect(manifest, isNot(contains('DEVICE_ADMIN_ENABLED')));
      expect(manifest, isNot(contains('CommitAdminReceiver')));
      expect(File('$_kotlin/CommitAdminReceiver.kt').existsSync(), isFalse);
      expect(
        File('android/app/src/main/res/xml/device_admin.xml').existsSync(),
        isFalse,
      );
    });

    test('"Clear data" in Android settings is not replaced or refused', () {
      expect(manifest, isNot(contains('manageSpaceActivity')));
      expect(manifest, isNot(contains('ManageSpaceActivity')));
      expect(File('$_kotlin/ManageSpaceActivity.kt').existsSync(), isFalse);
    });

    test('no native code touches device administration', () {
      for (final f in Directory(_kotlin).listSync().whereType<File>()) {
        final code = f.readAsStringSync();
        for (final api in [
          'DevicePolicyManager',
          'DeviceAdminReceiver',
          'ACTION_ADD_DEVICE_ADMIN',
          'removeActiveAdmin',
          'clearApplicationUserData',
          'setUninstallBlocked',
        ]) {
          expect(code, isNot(contains(api)), reason: '${f.path}: $api');
        }
      }
    });

    test('the app never blocks Settings, the installer or the launcher', () {
      final list = _read('$_kotlin/AppListProvider.kt');
      for (final pkg in [
        'com.android.settings',
        'com.android.packageinstaller',
        'com.google.android.packageinstaller',
        'com.android.permissioncontroller',
      ]) {
        expect(list, contains('"$pkg"'));
      }
    });

    test('the Dart side has no way to ask for uninstall protection', () {
      final bridgeCode = _read('lib/platform/platform_bridge.dart');
      expect(bridgeCode, isNot(contains('UninstallProtection')));
      for (final f
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        final code = f.readAsStringSync();
        expect(code, isNot(contains('uninstallProtection')), reason: f.path);
        expect(code, isNot(contains('Tamper protection')), reason: f.path);
      }
    });

    test('a challenge starts with blocking alone', () async {
      expect(controller.readyToStart, isTrue);
      await controller.startInstagram();
      expect(controller.active!.isLive, isTrue);
    });

    testWidgets('setup lists four switches and no tamper protection', (
      tester,
    ) async {
      bridge.accessibility = false;
      bridge.usage = false;
      await controller.refreshProtection();
      await controller.completeOnboarding();
      await pump(tester);
      await tap(tester, 'Start a challenge');
      final text = _screenText(tester);
      expect(text, contains('of 4 switched on'));
      expect(text.toLowerCase(), isNot(contains('tamper')));
      expect(text.toLowerCase(), isNot(contains('uninstall')));
      expect(text, contains('You stay in control'));
    });
  });

  group('losing the local copy is not a clean completion', () {
    test(
      'data cleared mid-challenge: restored, blocked again, not clean',
      () async {
        final server = ChallengeServer(DateTime(2026, 10, 5, 10));
        final phone = Phone(server);
        final app = await phone.open();
        await app.startInstagram(minutes: 60);
        final id = app.active!.id;

        // The user clears Commit's data (allowed) and opens it again.
        phone.bridge = FakeBridge();
        phone.platform.store.clear();
        final again = await phone.open();
        await again.syncWithBackend();
        expect(again.active!.id, id, reason: 'blocking resumes');
        expect(again.active!.restored, isTrue);

        phone.pass(const Duration(minutes: 61));
        await again.syncWithBackend();
        final done = again.history.first;
        expect(done.status, CommitmentStatus.completed);
        expect(CommitmentEngine.keptCleanly(done), isFalse);
        expect(again.stats.completed, 0, reason: 'not counted as kept');
        expect(
          server.events.map((e) => e['type']),
          contains('restored_on_device'),
        );
      },
    );

    test('an undisturbed challenge is still a clean completion', () async {
      await controller.startInstagram(minutes: 60);
      clock.advance(const Duration(minutes: 61));
      controller.tick();
      expect(CommitmentEngine.keptCleanly(controller.history.first), isTrue);
      expect(controller.stats.completed, 1);
    });

    testWidgets('a restored challenge is not celebrated', (tester) async {
      final server = ChallengeServer(clock.time);
      final phone = Phone(server);
      final first = await tester.runAsync(() async {
        final app = await phone.open();
        await app.startInstagram(minutes: 60);
        phone.bridge = FakeBridge();
        phone.platform.store.clear();
        final again = await phone.open();
        await again.syncWithBackend();
        await again.completeOnboarding();
        phone.pass(const Duration(minutes: 61));
        return again;
      });
      controller = first!;
      await pump(tester);
      final text = _screenText(tester);
      expect(text, contains('Challenge period ended'));
      expect(text, contains('not counted as fully kept'));
      expect(text, isNot(contains('Challenge complete')));
    });
  });

  group('Accessibility disclosure and consent', () {
    Future<void> openSetup(WidgetTester tester) async {
      bridge.accessibility = false;
      await controller.refreshProtection();
      await controller.completeOnboarding();
      await pump(tester);
      await tap(tester, 'Settings');
      await tap(tester, 'Blocking setup');
    }

    testWidgets('the disclosure is shown before Android settings open', (
      tester,
    ) async {
      await openSetup(tester);
      await tap(tester, 'Accessibility');
      expect(find.text(AccessibilityDisclosureScreen.title), findsOneWidget);
      expect(bridge.accessibilitySettingsOpened, 0);
      expect(find.text('Agree'), findsOneWidget);
      expect(find.text('No thanks'), findsOneWidget);
      final text = _screenText(tester);
      expect(text, contains('What Commit reads'));
      expect(text, contains('What Commit does not read'));
      expect(text, contains('What is stored or sent'));
    });

    testWidgets('"No thanks" opens nothing and records no consent', (
      tester,
    ) async {
      await openSetup(tester);
      await tap(tester, 'Accessibility');
      await tap(tester, 'No thanks');
      expect(bridge.accessibilitySettingsOpened, 0);
      expect(controller.accessibilityConsent, isFalse);
      expect(find.text('Set up blocking'), findsOneWidget);
      // Asking again shows the disclosure again.
      await tap(tester, 'Accessibility');
      expect(find.text(AccessibilityDisclosureScreen.title), findsOneWidget);
    });

    testWidgets('"Agree" records consent and then opens Android settings', (
      tester,
    ) async {
      await openSetup(tester);
      await tap(tester, 'Accessibility');
      await tap(tester, 'Agree');
      expect(controller.accessibilityConsent, isTrue);
      expect(bridge.accessibilitySettingsOpened, 1);
      expect(jsonDecode(bridge.disk!)['accessibilityConsent'], isTrue);
      // Consent was given: the next tap goes straight to settings.
      await tap(tester, 'Accessibility');
      expect(bridge.accessibilitySettingsOpened, 2);
      expect(find.text(AccessibilityDisclosureScreen.title), findsNothing);
    });

    testWidgets('"Turn on next step" also goes through the disclosure', (
      tester,
    ) async {
      await openSetup(tester);
      await tap(tester, 'Turn on next step');
      expect(find.text(AccessibilityDisclosureScreen.title), findsOneWidget);
      expect(bridge.accessibilitySettingsOpened, 0);
    });

    test('consent survives a restart', () async {
      await controller.acceptAccessibilityDisclosure();
      final again = await boot(bridge, clock);
      expect(again.accessibilityConsent, isTrue);
    });

    test('the disclosure says what is read, what is not, and what is sent', () {
      expect(AccessibilityDisclosureScreen.purpose, contains('one purpose'));
      expect(AccessibilityDisclosureScreen.reads, contains('name of the app'));
      expect(
        AccessibilityDisclosureScreen.neverReads,
        allOf(contains('messages'), contains('passwords'), contains('type')),
      );
      expect(
        AccessibilityDisclosureScreen.storedOrSent,
        allOf(contains('not saved'), contains('server')),
      );
      expect(
        AccessibilityDisclosureScreen.control,
        allOf(contains('not an accessibility tool'), contains('switch')),
      );
    });

    test(
      'the service is narrow and does not claim to be an accessibility tool',
      () {
        final config = _read(
          'android/app/src/main/res/xml/accessibility_service_config.xml',
        );
        expect(config, contains('android:canRetrieveWindowContent="false"'));
        expect(config, contains('typeWindowStateChanged'));
        expect(config, isNot(contains('isAccessibilityTool')));
        final description = _read(
          'android/app/src/main/res/values/strings.xml',
        );
        expect(description, contains('not an accessibility tool'));
        expect(description, isNot(contains('nothing it detects is sent')));
      },
    );
  });

  group('no real-money behaviour', () {
    testWidgets('the whole flow has four steps and never mentions money', (
      tester,
    ) async {
      await pump(tester);
      _expectNoMoney(tester, 'welcome');
      await tap(tester, 'Get started');
      _expectNoMoney(tester, 'home');
      await tap(tester, 'Start a challenge');
      expect(find.text('Step 1 of 4'), findsOneWidget);
      await tap(tester, 'Instagram');
      await tap(tester, 'Continue · 1 app');
      expect(find.text('Step 2 of 4'), findsOneWidget);
      _expectNoMoney(tester, 'duration');
      await tap(tester, '30 days');
      await tap(tester, 'Continue');
      expect(find.text('Step 3 of 4'), findsOneWidget);
      _expectNoMoney(tester, 'emergency');
      await tap(tester, 'Continue');
      expect(find.text('Step 4 of 4'), findsOneWidget);
      expect(find.text('Review & start'), findsOneWidget);
      _expectNoMoney(tester, 'review');
      expect(find.text(CommitmentEngine.plainConsentText), findsOneWidget);
      await tap(tester, CommitmentEngine.plainConsentText);
      await tap(tester, 'Start challenge');

      expect(controller.active!.commitmentAmount, 0);
      expect(controller.active!.payment, isNull);
      _expectNoMoney(tester, 'active challenge');
      expect(find.text('Emergency access'), findsWidgets);
    });

    testWidgets('blocked screen, emergency, history and guide have no money', (
      tester,
    ) async {
      await controller.completeOnboarding();
      await controller.startInstagram(amount: 0, emergencyLimit: 1);
      bridge.launchAction = 'blocked';
      await pump(tester);
      _expectNoMoney(tester, 'blocked screen');
      await tap(tester, 'Emergency access · 1 left');
      _expectNoMoney(tester, 'emergency confirmation');

      Navigator.of(tester.element(find.byType(Scaffold).first))
          .popUntil((r) => r.isFirst);
      await tester.pumpAndSettle();
      await tap(tester, 'How Commit works');
      _expectNoMoney(tester, 'guide (except the one "free" line)');
      expect(_screenText(tester), contains('never charges you anything'));
    });

    testWidgets('a challenge made by an older version shows no money either', (
      tester,
    ) async {
      await controller.completeOnboarding();
      await controller.startInstagram(amount: 500, emergencyLimit: 1);
      await pump(tester);
      await tap(tester, 'Continue challenge');
      _expectNoMoney(tester, 'old challenge');
      clock.advance(const Duration(days: 2));
      controller.tick();
      await tester.pumpAndSettle();
      _expectNoMoney(tester, 'completion of an old challenge');
      await tap(tester, 'Done');
      await tap(tester, 'History');
      _expectNoMoney(tester, 'history');
    });

    testWidgets('settings offer no payment screens', (tester) async {
      await controller.completeOnboarding();
      await pump(tester);
      await tap(tester, 'Settings');
      _expectNoMoney(tester, 'settings');
    });

    test('ending early is refused before anything leaves the phone', () async {
      final server = ChallengeServer(DateTime(2026, 10, 5, 10));
      final phone = Phone(server);
      final app = await phone.open();
      await app.startInstagram(minutes: 120, amount: 0);
      await expectLater(
        app.endChallengeWithPayment(),
        throwsA(
          isA<CommitmentException>().having(
            (e) => e.error,
            'error',
            CommitmentError.endEarlyUnavailable,
          ),
        ),
      );
      expect(server.count('POST', '/end-early'), 0);
      expect(app.active!.isLive, isTrue);
      expect(app.active!.payment, isNull);
    });

    test(
      'a new challenge is sent to the server with no amount of money',
      () async {
        final server = ChallengeServer(DateTime(2026, 10, 5, 10));
        final phone = Phone(server);
        final app = await phone.open();
        await app.startInstagram(minutes: 60, amount: 0);
        final sent = jsonDecode(
          server.requests.lastWhere((r) => r.method == 'POST').body!,
        );
        expect(sent['amountRupees'], 0);
        expect(sent['consentVersion'], CommitmentEngine.consentVersion);
        expect(server.challenges.single['amount'], 0);
      },
    );

    test('no payment provider, UPI query or payment permission is present', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      expect(manifest, isNot(contains('upi')));
      expect(manifest, isNot(contains('com.android.vending.BILLING')));
      final pubspec = _read('pubspec.yaml');
      for (final sdk in [
        'razorpay',
        'stripe',
        'in_app_purchase',
        'upi',
        'pay:',
      ]) {
        expect(pubspec.toLowerCase(), isNot(contains(sdk)));
      }
      expect(const UnconfiguredPaymentServiceProbe().isConfigured, isFalse);
    });

    test('the consent sentence promises no payment', () {
      expect(CommitmentEngine.plainConsentText, isNot(contains('pay')));
      expect(CommitmentEngine.plainConsentText, isNot(contains('₹')));
    });
  });

  group('privacy wording matches the architecture', () {
    test(
      'it says what is sent and never that everything stays on the phone',
      () {
        final p = privacySummary;
        expect(p, contains('No account is required'));
        expect(p, contains('server'));
        expect(p, contains('random ID'));
        expect(p, contains('apps you chose'));
        expect(p, contains('start and end time'));
        expect(p, contains('encrypted (HTTPS)'));
        expect(p, contains('no analytics'));
        expect(p, isNot(contains('stored on this phone, and')));
        expect(p, isNot(contains('for one thing')));
        expect(p.toLowerCase(), isNot(contains('no personal information')));
        expect(p.toLowerCase(), isNot(contains('anonymous')));
      },
    );

    test('no screen claims that data stays only on the phone', () {
      for (final f
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        final code = f.readAsStringSync();
        for (final claim in [
          'Everything stays on this phone',
          'Nothing it detects leaves your phone',
          'no personal information',
        ]) {
          expect(code, isNot(contains(claim)), reason: f.path);
        }
      }
    });

    testWidgets('Settings shows the corrected privacy text', (tester) async {
      await controller.completeOnboarding();
      await pump(tester);
      await tap(tester, 'Settings');
      expect(find.text('What Commit stores and sends'), findsOneWidget);
      await tap(tester, 'Privacy');
      expect(find.text(privacySummary), findsOneWidget);
    });

    test(
      'the privacy policy link opens only when an address is configured',
      () {
        // No address is compiled in until the policy is published.
        expect(Features.privacyPolicyUrl, isEmpty);
      },
    );
  });

  group('existing behaviour is unchanged', () {
    test(
      'blocking state is written for the native blocker as before',
      () async {
        await controller.startInstagram(minutes: 60);
        final doc = jsonDecode(bridge.disk!) as Map<String, Object?>;
        final saved = (doc['commitments'] as List).single as Map;
        expect(jsonEncode(saved), contains(instagram));
        expect(controller.activeState, ChallengeState.active);
      },
    );

    test(
      'offline: protection continues and events wait for the network',
      () async {
        final server = ChallengeServer(DateTime(2026, 10, 5, 10));
        final phone = Phone(server);
        final app = await phone.open();
        await app.startInstagram(minutes: 120, amount: 0, emergencyLimit: 1);
        server.offline = true;
        await app.startEmergency();
        await app.syncWithBackend();
        expect(app.active!.isLive, isTrue);
        expect(app.outbox, isNotEmpty);
        server.offline = false;
        await app.syncWithBackend();
        expect(app.outbox, isEmpty);
        expect(server.emergencyUses, hasLength(1));
      },
    );

    test('server sync still completes a challenge at its end time', () async {
      final server = ChallengeServer(DateTime(2026, 10, 5, 10));
      final phone = Phone(server);
      final app = await phone.open();
      await app.startInstagram(minutes: 60, amount: 0);
      phone.pass(const Duration(minutes: 61));
      await app.syncWithBackend();
      expect(server.challenges.single['status'], 'completed');
      expect(CommitmentEngine.keptCleanly(app.history.first), isTrue);
    });
  });
}

/// Reads the app's default payment service without importing UI code.
class UnconfiguredPaymentServiceProbe {
  const UnconfiguredPaymentServiceProbe();
  bool get isConfigured => CommitController(
    bridge: FakeBridge(),
    clock: FakeClock(),
  ).payments.isConfigured;
}
