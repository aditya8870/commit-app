import 'package:app/app.dart';
import 'package:app/core/commitment.dart';
import 'package:app/core/commitment_engine.dart';
import 'package:app/core/payment.dart';
import 'package:app/data/commit_controller.dart';
import 'package:app/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeBridge bridge;
  late FakeClock clock;
  late CommitController controller;

  Future<void> pump(
    WidgetTester tester, {
    Size size = const Size(1080, 2400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CommitApp(controller: controller));
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.pumpAndSettle();
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    withDormantPayments();
    bridge = FakeBridge();
    clock = FakeClock();
    controller = await boot(bridge, clock);
  });

  testWidgets('first launch leads to Home', (tester) async {
    await pump(tester);
    expect(find.text('Decide before temptation.'), findsOneWidget);
    await tap(tester, 'Get started');
    expect(find.text('Start a challenge'), findsOneWidget);
    expect(find.text('No active challenge'), findsOneWidget);
  });

  testWidgets('first launch opens setup when permissions are missing', (
    tester,
  ) async {
    bridge.accessibility = false;
    bridge.usage = false;
    await controller.refreshProtection();
    await pump(tester);
    await tap(tester, 'Get started');
    expect(find.text('Set up blocking'), findsOneWidget);
    expect(find.text('Blocking permission required.'), findsOneWidget);
  });

  testWidgets('five-step flow: apps, duration, emergency, amount, review', (
    tester,
  ) async {
    await controller.completeOnboarding();
    await pump(tester);
    await tap(tester, 'Start a challenge');

    expect(find.text('Step 1 of 5'), findsOneWidget);
    await tap(tester, 'Instagram');
    await tap(tester, 'YouTube');
    await tap(tester, 'Continue · 2 apps');

    expect(find.text('Step 2 of 5'), findsOneWidget);
    for (final label in [
      '2 min',
      '5 min',
      '10 min',
      '15 min',
      '30 min',
      '1 hr',
      '2 hr',
      '3 hr',
      '6 hr',
      '12 hr',
      '1 day',
      '2 days',
      '3 days',
      '7 days',
      '14 days',
      '30 days',
      'Custom duration',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tap(tester, '1 day');
    await tap(tester, 'Continue');

    expect(find.text('Step 3 of 5'), findsOneWidget);
    for (final label in ['None', '1 use', '2 uses', '3 uses']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tap(tester, 'Continue'); // default: 1 use, 5 minutes

    // Step 4: Commitment Amount is required.
    expect(find.text('Step 4 of 5'), findsOneWidget);
    expect(find.text('COMMITMENT AMOUNT'), findsOneWidget);
    for (final label in [
      '₹100',
      '₹500',
      '₹1,000',
      '₹2,500',
      '₹5,000',
      '₹10,000',
      'Custom amount',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tap(tester, 'Continue');
    expect(find.text('Step 4 of 5'), findsOneWidget, reason: 'no amount yet');
    await tap(tester, '₹100');
    await tap(tester, 'Continue');

    // Step 5: review with explicit confirmation.
    expect(find.text('Step 5 of 5'), findsOneWidget);
    expect(find.text('Instagram'), findsOneWidget);
    expect(find.text('YouTube'), findsOneWidget);
    expect(find.text('1 day'), findsOneWidget);
    expect(find.text('1 × 5 minutes'), findsOneWidget);
    expect(find.text('₹100'), findsOneWidget);
    expect(find.text('₹100 becomes payable'), findsOneWidget);
    expect(find.text(paymentsOffNote), findsOneWidget);

    await tap(tester, 'Tick the box to start');
    expect(controller.active, isNull, reason: 'must tick "I understand" first');
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tap(tester, 'Start challenge');

    final c = controller.active!;
    expect(c.appNames, ['Instagram', 'YouTube']);
    expect(c.durationMinutes, 1440);
    expect(c.emergencyLimit, 1);
    expect(c.commitmentAmount, 100);

    // Active challenge screen keeps the amount visible.
    expect(find.text('TIME REMAINING'), findsOneWidget);
    expect(find.text("You're doing it."), findsOneWidget);
    expect(find.text('₹100'), findsOneWidget);
    expect(find.text('1 of 1 left'), findsOneWidget);
    expect(find.text('Back to home'), findsOneWidget);
    expect(find.text('End challenge early'), findsOneWidget);
  });

  testWidgets('custom amount and custom duration can be entered', (
    tester,
  ) async {
    await controller.completeOnboarding();
    await pump(tester);
    await tap(tester, 'Start a challenge');
    await tap(tester, 'Instagram');
    await tap(tester, 'Continue · 1 app');
    await tap(tester, 'Custom duration');
    await tester.enterText(find.byType(TextField), '45');
    await tester.pumpAndSettle();
    await tap(tester, 'Set');
    expect(find.text('Custom: 45 minutes'), findsOneWidget);
    await tap(tester, 'Continue');
    await tap(tester, 'Continue');
    await tap(tester, 'Custom amount');
    for (final bad in ['99', '10001']) {
      await tester.enterText(find.byType(TextField), bad);
      await tester.pumpAndSettle();
      await tap(tester, 'Set');
      expect(find.text('Custom amount'), findsWidgets, reason: '₹$bad refused');
    }
    await tester.enterText(find.byType(TextField), '750');
    await tester.pumpAndSettle();
    await tap(tester, 'Set');
    expect(find.text('Custom: ₹750'), findsOneWidget);
  });

  testWidgets('screens fit a small phone without overflow', (tester) async {
    await controller.completeOnboarding();
    await pump(tester, size: const Size(720, 1280));
    await tap(tester, 'Start a challenge');
    await tester.scrollUntilVisible(
      find.text('Instagram'),
      80,
      scrollable: find.byType(Scrollable).first,
    );
    await tap(tester, 'Instagram');
    await tap(tester, 'Continue · 1 app');
    await tap(tester, '30 days');
    await tap(tester, 'Continue');
    await tap(tester, 'Continue');
    await tap(tester, '₹500');
    await tap(tester, 'Continue');
    expect(tester.takeException(), isNull);
    expect(find.text('Step 5 of 5'), findsOneWidget);
  });

  testWidgets('without permission the flow asks for it and cannot start', (
    tester,
  ) async {
    bridge.accessibility = false;
    bridge.usage = false;
    await controller.refreshProtection();
    await controller.completeOnboarding();
    await pump(tester);
    await tap(tester, 'Start a challenge');
    expect(find.text('Blocking permission required.'), findsOneWidget);
    expect(find.text('Select apps'), findsNothing);
  });

  testWidgets('blocked screen, emergency access is free, automatic re-lock', (
    tester,
  ) async {
    await controller.completeOnboarding();
    await controller.startInstagram(emergencyLimit: 1, emergencyMinutes: 5);
    await pump(tester);
    expect(find.text('Start a challenge'), findsNothing);
    expect(find.text("You're doing great."), findsOneWidget);
    expect(find.textContaining('₹'), findsNothing, reason: 'no money on Home');

    clock.advance(const Duration(hours: 4, minutes: 18));
    bridge.handler!('blocked');
    await tester.pumpAndSettle();
    expect(find.text("You're in a challenge."), findsOneWidget);
    expect(find.text('Instagram is blocked for'), findsOneWidget);
    expect(find.text('19h 42m'), findsOneWidget);
    expect(find.text('Back to challenge'), findsOneWidget);
    expect(find.text('End challenge early'), findsOneWidget);

    await tap(tester, 'Emergency access · 1 left');
    expect(controller.active!.emergencyAccessCount, 0);
    await tap(tester, 'Use emergency access');
    expect(controller.active!.emergencyRemaining, 0);
    expect(controller.active!.payment, isNull, reason: 'emergency is free');
    expect(find.text('5 min'), findsOneWidget);

    clock.advance(const Duration(minutes: 5, seconds: 1));
    bridge.handler!('blocked');
    await tester.pumpAndSettle();
    expect(find.text('Emergency access has ended.'), findsOneWidget);
    expect(find.text('No emergency access left'), findsOneWidget);
    // Ending the challenge is still available.
    expect(find.text('End challenge early'), findsOneWidget);
  });

  testWidgets(
    'end challenge: confirmation first, and no provider means no charge',
    (tester) async {
      await controller.completeOnboarding();
      await controller.startInstagram();
      await pump(tester);
      clock.advance(const Duration(hours: 4, minutes: 18));
      bridge.handler!('blocked');
      await tester.pumpAndSettle();

      await tap(tester, 'End challenge early');
      expect(find.text('End this challenge?'), findsOneWidget);
      expect(
        find.text(
          'If you end the challenge now, your ₹100 Commitment Amount will become payable.',
        ),
        findsOneWidget,
      );
      expect(find.text('You still have 19h 42m remaining.'), findsOneWidget);
      expect(controller.active!.payment, isNull, reason: 'nothing started');

      await tap(tester, 'End challenge — ₹100');
      expect(find.text('Payment'), findsOneWidget);
      expect(find.textContaining('Payments are not connected'), findsOneWidget);
      expect(find.text('Pay ₹100'), findsNothing);
      expect(find.textContaining('uccessful'), findsNothing);
      expect(controller.active, isNotNull);

      await tap(tester, 'Keep my commitment');
      expect(controller.active, isNotNull);
      expect(find.text('Continue challenge'), findsOneWidget);
    },
  );

  testWidgets('Keep My Commitment on the confirmation changes nothing', (
    tester,
  ) async {
    await controller.completeOnboarding();
    await controller.startInstagram();
    await pump(tester);
    await tap(tester, 'Continue challenge');
    await tap(tester, 'End challenge early');
    await tap(tester, 'Keep my commitment');
    expect(find.text("You're doing it."), findsOneWidget);
    expect(controller.active!.payment, isNull);
  });

  group('with a payment provider connected (test double)', () {
    late FakePayments pay;

    setUp(() async {
      pay = FakePayments();
      controller = await boot(bridge, clock, payments: pay);
      await controller.completeOnboarding();
      await controller.startInstagram();
      clock.advance(const Duration(hours: 4, minutes: 18));
    });

    Future<void> openPayment(WidgetTester tester) async {
      await pump(tester);
      await tap(tester, 'Continue challenge');
      await tap(tester, 'End challenge early');
      await tap(tester, 'End challenge — ₹100');
    }

    testWidgets('verified payment shows "Challenge ended"', (tester) async {
      pay.succeedWith('txn_42', clock.time);
      await openPayment(tester);
      expect(controller.active, isNotNull, reason: 'not paid until tapped');
      await tap(tester, 'Pay ₹100');
      expect(find.text('Challenge ended'), findsOneWidget);
      expect(
        find.text('Your ₹100 Commitment Amount has been paid.'),
        findsOneWidget,
      );
      expect(find.text('Payment successful'), findsOneWidget);
      expect(find.text('txn_42'), findsOneWidget);
      expect(controller.active, isNull);
      await tap(tester, 'Done');
      expect(find.text('Start a challenge'), findsOneWidget);
    });

    testWidgets('cancelled payment keeps the challenge and offers a retry', (
      tester,
    ) async {
      pay.onPay = (_) => const PaymentOutcome(PaymentStatus.cancelled);
      await openPayment(tester);
      await tap(tester, 'Pay ₹100');
      expect(find.text('Payment cancelled'), findsOneWidget);
      expect(find.text('Your challenge is still active.'), findsOneWidget);
      expect(find.text('Try again · ₹100'), findsOneWidget);
      expect(controller.active, isNotNull);
    });

    testWidgets('pending payment offers a status check, not a second charge', (
      tester,
    ) async {
      pay.onPay = (_) => const PaymentOutcome(PaymentStatus.pending);
      await openPayment(tester);
      await tap(tester, 'Pay ₹100');
      expect(find.text('Check payment status'), findsOneWidget);
      expect(find.text('Pay ₹100'), findsNothing);
      await tap(tester, 'Check payment status');
      expect(pay.payCalls, 1);
      expect(controller.active, isNotNull);
    });
  });

  testWidgets(
    'a payment that landed after the end is shown as being refunded',
    (tester) async {
      final pay = FakePayments();
      final server = FakeBackend(clock, pay);
      controller = await boot(bridge, clock, payments: pay, backend: server);
      await controller.completeOnboarding();
      await controller.startInstagram(minutes: 60);
      final id = controller.active!.id;
      clock.advance(const Duration(minutes: 20));
      pay.onPay = (_) => const PaymentOutcome(PaymentStatus.pending);
      await controller.endChallengeWithPayment();
      clock.advance(const Duration(hours: 1));
      controller.tick();
      pay.server[FakeBackend.ref(id)] = PaymentOutcome(
        PaymentStatus.successful,
        transactionId: 'txn_late',
        paidAt: clock.time,
        refund: RefundStatus.pending,
      );
      await controller.reconcilePayment();
      await pump(tester);
      expect(find.text('Your ₹100 payment is being refunded.'), findsOneWidget);
      expect(find.text('Amount payable'), findsNothing);
    },
  );

  testWidgets('completion screen says the amount was not charged', (
    tester,
  ) async {
    await controller.completeOnboarding();
    await controller.createCommitment(
      consentAccepted: true,
      apps: const [AppRef(instagram, 'Instagram'), AppRef(youtube, 'YouTube')],
      durationMinutes: 60,
      amount: 100,
    );
    await pump(tester);
    clock.advance(const Duration(hours: 1));
    controller.tick();
    await tester.pumpAndSettle();
    expect(find.text('Challenge complete 🎉'), findsOneWidget);
    expect(find.text('You kept your commitment.'), findsOneWidget);
    expect(find.text('1 hour completed.'), findsOneWidget);
    expect(find.text('Amount payable'), findsOneWidget);
    expect(find.text('₹0'), findsOneWidget);
    expect(find.text('Start another challenge'), findsOneWidget);
    await tap(tester, 'Done');
    expect(find.text('Start a challenge'), findsOneWidget);

    await tap(tester, 'History');
    await tester.pumpAndSettle();
    expect(find.text('Instagram + YouTube'), findsOneWidget);
    expect(find.text('✓ Completed'), findsOneWidget);
    expect(find.textContaining('₹0 payable'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
  });

  // Changed in 2.9.0: tamper protection no longer exists.
  testWidgets('a challenge starts without any tamper protection step', (
    tester,
  ) async {
    await controller.refreshProtection();
    await controller.completeOnboarding();
    await pump(tester);
    await tap(tester, 'Start a challenge');
    expect(find.textContaining('Tamper protection'), findsNothing);
    expect(
      find.text('Which apps do you want to stay away from?'),
      findsOneWidget,
    );
  });

  testWidgets('interrupted challenge is not celebrated at the end', (
    tester,
  ) async {
    await controller.completeOnboarding();
    await controller.startInstagram(minutes: 60);
    clock.advance(const Duration(minutes: 10));
    bridge.nativeEvents.add({
      'type': 'forceStopped',
      'at': clock.time.millisecondsSinceEpoch,
    });
    clock.advance(const Duration(minutes: 50));
    controller = await boot(bridge, clock);
    await pump(tester);
    expect(find.text('Challenge period ended'), findsOneWidget);
    expect(find.text('Challenge complete 🎉'), findsNothing);
    expect(
      find.textContaining('Protection was interrupted once'),
      findsOneWidget,
    );
    expect(find.text('Amount payable'), findsOneWidget);
  });

  testWidgets('protection-disabled warning is shown during a challenge', (
    tester,
  ) async {
    await controller.completeOnboarding();
    await controller.startInstagram();
    bridge.accessibility = false;
    bridge.usage = false;
    await controller.refreshProtection();
    await pump(tester);
    expect(find.text('Your protection has been interrupted.'), findsOneWidget);
    expect(find.text('Your challenge is still active.'), findsOneWidget);
    expect(find.text('Commitment Amount: ₹100'), findsWidgets);
    expect(
      find.text('Please restore protection to continue your commitment.'),
      findsOneWidget,
    );
    expect(find.text('Protection interrupted'), findsOneWidget);
    expect(find.textContaining('paid'), findsNothing);
  });

  testWidgets('start another challenge from the completion screen', (
    tester,
  ) async {
    await controller.completeOnboarding();
    await controller.startInstagram(minutes: 60);
    await pump(tester);
    clock.advance(const Duration(hours: 1));
    controller.tick();
    await tester.pumpAndSettle();
    await tap(tester, 'Start another challenge');
    expect(controller.pendingCompletion, isNull);
    expect(find.text('Step 1 of 5'), findsOneWidget);
  });

  testWidgets('payment screens preview is labelled and changes nothing', (
    tester,
  ) async {
    await controller.completeOnboarding();
    await controller.startInstagram();
    await pump(tester);
    await tap(tester, 'Settings');
    await tester.pumpAndSettle();
    await tap(tester, 'Payment screens');
    expect(find.text('Design preview'), findsOneWidget);
    expect(find.textContaining('No payment is being made'), findsOneWidget);
    expect(controller.active!.payment, isNull);
    expect(controller.active, isNotNull);
  });

  testWidgets('empty history and how-it-works explain themselves', (
    tester,
  ) async {
    await controller.completeOnboarding();
    await pump(tester);
    await tap(tester, 'History');
    await tester.pumpAndSettle();
    expect(find.text('No challenges yet'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tap(tester, 'Settings');
    await tester.pumpAndSettle();
    await tap(tester, 'How Commit works');
    expect(find.text('What makes it payable'), findsOneWidget);
    expect(find.text('What never costs anything'), findsOneWidget);
  });

  testWidgets('time left is shown without ticking seconds', (tester) async {
    await controller.completeOnboarding();
    await controller.startInstagram(minutes: 5);
    await pump(tester);
    clock.advance(const Duration(seconds: 90));
    controller.tick();
    await tester.pumpAndSettle();
    expect(find.text('4 min remaining'), findsOneWidget);
    clock.advance(const Duration(minutes: 3));
    controller.tick();
    await tester.pumpAndSettle();
    expect(find.text('Under 1 min remaining'), findsOneWidget);
    // Reopening the app shows the same time: it comes from the saved end time.
    controller = await boot(bridge, clock);
    await pump(tester);
    expect(find.text('Under 1 min remaining'), findsOneWidget);
    // At zero the existing completion screen appears.
    clock.advance(const Duration(seconds: 31));
    controller.tick();
    await tester.pumpAndSettle();
    expect(find.text('Challenge complete 🎉'), findsOneWidget);
    expect(controller.active, isNull);
  });

  testWidgets('the app can be explored during a challenge, but only one runs', (
    tester,
  ) async {
    await controller.completeOnboarding();
    await controller.startInstagram();
    final id = controller.active!.id;
    await pump(tester);
    expect(find.text('Stay focused on your goal.'), findsOneWidget);

    await tap(tester, 'History');
    expect(find.text('All challenges'.toUpperCase()), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tap(tester, 'How Commit works');
    expect(find.text('What makes it payable'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tap(tester, 'Settings');
    expect(find.text('Blocking setup'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tap(tester, 'New challenge');
    expect(
      find.text('You already have a challenge in progress.'),
      findsOneWidget,
    );
    expect(
      find.text('Finish your current challenge before starting a new one.'),
      findsOneWidget,
    );
    expect(find.text('Step 1 of 5'), findsNothing);
    await tap(tester, 'Open challenge');
    expect(find.text('TIME REMAINING'), findsOneWidget);
    expect(controller.active!.id, id);
    await expectLater(
      controller.startInstagram(),
      throwsA(isA<CommitmentException>()),
    );
  });
}
