import 'package:flutter/material.dart';

import '../../core/commitment.dart';
import '../../core/commitment_engine.dart';
import '../../core/payment.dart';
import '../format.dart';
import '../widgets.dart';
import 'create_flow.dart';

/// First step of ending early: a clear pause. Nothing is paid here.
class EndChallengeConfirmScreen extends StatelessWidget {
  const EndChallengeConfirmScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = CommitScope.of(context);
    final c = controller.active;
    if (c == null) {
      return const AppPage(
        title: 'End challenge',
        centered: true,
        children: [Note('There is no active challenge.', center: true)],
      );
    }
    final now = controller.now;
    final canEnd = CommitmentEngine.canEndEarly(c, now);
    final amount = formatAmount(c.commitmentAmount);
    return AppPage(
      title: 'End challenge',
      actions: [
        PrimaryButton(
          'Keep my commitment',
          onPressed: () => Navigator.of(context).pop(),
        ),
        SecondaryButton(
          'End challenge — $amount',
          onPressed: canEnd
              ? () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => const PaymentScreen(),
                  ),
                )
              : null,
        ),
      ],
      children: [
        const Text('End this challenge?', style: AppText.heading),
        const SizedBox(height: AppSpace.md),
        Text(
          'You still have ${formatTimeLeft(CommitmentEngine.remaining(c, now))} remaining.',
          style: AppText.subheading,
        ),
        const SizedBox(height: AppSpace.md),
        Text(
          'If you end the challenge now, your $amount Commitment Amount will become payable.',
          style: AppText.body,
        ),
        const SizedBox(height: AppSpace.xl),
        SummaryCard(
          children: [
            OutcomeRow(
              icon: Icons.check,
              when: 'Keep going',
              result: 'You pay ₹0',
              tone: Tone.success,
            ),
            OutcomeRow(
              icon: Icons.flag_outlined,
              when: 'End now',
              result: '$amount becomes payable',
              tone: Tone.warm,
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        Note(
          canEnd
              ? 'Nothing is charged on this screen. You will be asked to confirm the payment on the next one.'
              : CommitmentError.endingSoon.message,
        ),
      ],
    );
  }
}

/// Short payment status for a details row.
String paymentStatusLabel(PaymentStatus s) => switch (s) {
  PaymentStatus.notStarted => 'Not started',
  PaymentStatus.initiated => 'Started',
  PaymentStatus.pending => 'Pending',
  PaymentStatus.successful => 'Paid',
  PaymentStatus.failed => 'Failed',
  PaymentStatus.cancelled => 'Cancelled',
  PaymentStatus.verificationFailed => 'Not confirmed yet',
  PaymentStatus.networkError => 'Connection problem',
};

/// Every payment situation the app can show.
enum PaymentView {
  notConnected,
  required,
  processing,
  verifying,
  pending,
  failed,
  cancelled,
  unconfirmed,
  offline,
  expired,
  successful,
  refundPending,
  refunded,
  completed,
}

/// One card per payment situation. The wording lives here so every screen
/// says the same thing.
class PaymentStateCard extends StatelessWidget {
  const PaymentStateCard(this.view, {super.key, required this.amount});
  final PaymentView view;

  /// Formatted amount, e.g. "₹100".
  final String amount;

  static const _safe = 'You will not be charged twice.';

  @override
  Widget build(BuildContext context) {
    final (
      Tone tone,
      IconData icon,
      String title,
      List<String> lines,
    ) = switch (view) {
      PaymentView.notConnected => (
        Tone.warm,
        Icons.construction,
        'Payments are not connected yet',
        [
          'This is a test version, so a challenge cannot be ended early yet.',
          'Nothing has been charged.',
        ],
      ),
      PaymentView.required => (
        Tone.brand,
        Icons.lock_outline,
        'Payment required',
        [
          'Pay $amount to end this challenge.',
          'You pay on the payment provider\'s secure screen. Commit never sees your card or UPI details.',
        ],
      ),
      PaymentView.processing => (
        Tone.brand,
        Icons.hourglass_top,
        'Processing payment…',
        ['Please keep this screen open.'],
      ),
      PaymentView.verifying => (
        Tone.brand,
        Icons.verified_outlined,
        'Confirming your payment…',
        ['This usually takes a few seconds.'],
      ),
      PaymentView.pending => (
        Tone.warm,
        Icons.schedule,
        'Payment pending',
        [
          'Your payment is still being processed. Check again in a moment.',
          _safe,
        ],
      ),
      PaymentView.failed => (
        Tone.warm,
        Icons.error_outline,
        'Payment failed',
        ['The payment did not go through. You can try again.'],
      ),
      PaymentView.cancelled => (
        Tone.neutral,
        Icons.close,
        'Payment cancelled',
        ['You cancelled the payment. Nothing has changed.'],
      ),
      PaymentView.unconfirmed => (
        Tone.warm,
        Icons.help_outline,
        'Payment not confirmed yet',
        ['We could not confirm this payment. Check again in a moment.', _safe],
      ),
      PaymentView.offline => (
        Tone.warm,
        Icons.wifi_off,
        'No connection',
        ['Check your internet and try again.', _safe],
      ),
      PaymentView.expired => (
        Tone.warm,
        Icons.schedule,
        'This payment attempt has expired',
        ['Check its status to see whether anything was paid.', _safe],
      ),
      PaymentView.successful => (
        Tone.success,
        Icons.check_circle_outline,
        'Payment successful',
        ['Your $amount Commitment Amount has been paid.'],
      ),
      PaymentView.refundPending => (
        Tone.brand,
        Icons.replay,
        'Refund in progress',
        ['Your $amount payment is being refunded.'],
      ),
      PaymentView.refunded => (
        Tone.success,
        Icons.replay,
        'Refunded',
        ['Your $amount payment has been refunded.'],
      ),
      PaymentView.completed => (
        Tone.success,
        Icons.check_circle_outline,
        'Challenge completed',
        ['Amount payable: ₹0.'],
      ),
    };
    return NoticeCard(tone: tone, icon: icon, title: title, lines: lines);
  }
}

/// Which card matches what is on record for the running challenge.
PaymentView _viewFor({
  required bool connected,
  required bool busy,
  required PaymentRecord? record,
  required DateTime now,
}) {
  if (busy) return PaymentView.processing;
  if (!connected) return PaymentView.notConnected;
  final status = record?.status ?? PaymentStatus.notStarted;
  if (record != null && status.mustVerifyBeforeRetry && record.isExpired(now)) {
    return PaymentView.expired;
  }
  return switch (status) {
    PaymentStatus.notStarted => PaymentView.required,
    PaymentStatus.initiated || PaymentStatus.pending => PaymentView.pending,
    PaymentStatus.successful => PaymentView.verifying,
    PaymentStatus.failed => PaymentView.failed,
    PaymentStatus.cancelled => PaymentView.cancelled,
    PaymentStatus.verificationFailed => PaymentView.unconfirmed,
    PaymentStatus.networkError => PaymentView.offline,
  };
}

/// Second step: the user starts the payment themselves. The challenge ends
/// only when the payment is confirmed; this screen never decides that.
class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  String? _error;

  Future<void> _pay() async {
    final controller = CommitScope.of(context);
    if (controller.paymentBusy) return; // repeated taps do nothing
    setState(() => _error = null);
    try {
      await controller.endChallengeWithPayment();
      // On confirmed success the app returns to the root by itself and shows
      // the "Challenge ended" screen.
    } on CommitmentException catch (e) {
      if (mounted) setState(() => _error = e.error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Something went wrong. Nothing was changed.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = CommitScope.of(context);
    final c = controller.active;
    if (c == null) {
      return const AppPage(
        title: 'Payment',
        centered: true,
        children: [Note('There is no active challenge.', center: true)],
      );
    }
    final connected = controller.payments.isConfigured;
    final busy = controller.paymentBusy;
    final record = c.payment;
    final status = record?.status ?? PaymentStatus.notStarted;
    final recheck = status.mustVerifyBeforeRetry;
    final amount = formatAmount(c.commitmentAmount);
    final attempted = record != null && status != PaymentStatus.notStarted;

    return AppPage(
      title: 'Payment',
      actions: [
        PrimaryButton(
          'Keep my commitment',
          onPressed: busy
              ? null
              : () => Navigator.of(context).popUntil((r) => r.isFirst),
        ),
        if (connected)
          SecondaryButton(
            busy
                ? 'Processing…'
                : recheck
                ? 'Check payment status'
                : attempted
                ? 'Try again · $amount'
                : 'Pay $amount',
            onPressed: busy ? null : _pay,
          ),
      ],
      children: [
        const Text('End challenge early', style: AppText.heading),
        const SizedBox(height: AppSpace.lg),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              children: [
                const Text('COMMITMENT AMOUNT', style: AppText.label),
                const SizedBox(height: AppSpace.sm),
                Text(amount, style: AppText.timer),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        if (_error != null && !busy)
          NoticeCard(icon: Icons.error_outline, title: _error!)
        else
          PaymentStateCard(
            _viewFor(
              connected: connected,
              busy: busy,
              record: record,
              now: controller.now,
            ),
            amount: amount,
          ),
        if (busy) ...[
          const SizedBox(height: AppSpace.lg),
          const Center(child: CircularProgressIndicator()),
        ],
        const SizedBox(height: AppSpace.lg),
        const NoticeCard(
          tone: Tone.brand,
          icon: Icons.timer_outlined,
          title: 'Your challenge is still active.',
          lines: ['It only ends after the payment is confirmed.'],
        ),
        if (record != null && record.reference.isNotEmpty) ...[
          const SizedBox(height: AppSpace.lg),
          Note('Reference: ${record.reference}', center: true),
        ],
      ],
    );
  }
}

/// Shown once after a confirmed payment ended the challenge.
class EndedEarlyScreen extends StatelessWidget {
  const EndedEarlyScreen({super.key, required this.commitment});
  final Commitment commitment;

  @override
  Widget build(BuildContext context) {
    final c = commitment;
    final p = c.payment;
    final controller = CommitScope.of(context);
    final amount = formatAmount(c.commitmentAmount);
    final view = switch (p?.refund) {
      RefundStatus.pending => PaymentView.refundPending,
      RefundStatus.refunded => PaymentView.refunded,
      _ => PaymentView.successful,
    };

    Future<void> another() async {
      final nav = Navigator.of(context);
      await controller.acknowledgeCompletion(c.id);
      await controller.refreshProtection();
      nav.push(
        MaterialPageRoute<void>(
          builder: (_) => controller.readyToStart
              ? const SelectAppsScreen()
              : const PermissionScreen(continueToFlow: true),
        ),
      );
    }

    return AppPage(
      centered: true,
      actions: [
        PrimaryButton('Start another challenge', onPressed: another),
        QuietButton(
          'Done',
          onPressed: () => controller.acknowledgeCompletion(c.id),
        ),
      ],
      children: [
        const Text(
          'Challenge ended',
          textAlign: TextAlign.center,
          style: AppText.heading,
        ),
        const SizedBox(height: AppSpace.sm),
        const Text(
          'Your apps are unlocked. You can start again whenever you are ready.',
          textAlign: TextAlign.center,
          style: AppText.bodyMuted,
        ),
        const SizedBox(height: AppSpace.xl),
        PaymentStateCard(view, amount: amount),
        const SizedBox(height: AppSpace.lg),
        SummaryCard(
          children: [
            InfoRow('Protected apps', c.appNames.join('\n')),
            InfoRow('Time that was left', formatRemaining(c.remainingAtEnd)),
            InfoRow('Commitment Amount', amount),
            if (p?.transactionId != null)
              InfoRow('Payment ID', p!.transactionId!),
            if (p?.paidAt != null)
              InfoRow('Paid on', formatDateTime(p!.paidAt!)),
          ],
        ),
      ],
    );
  }
}

/// Design preview of every payment state, reachable from Settings. It makes
/// no payment and changes nothing.
class PaymentPreviewScreen extends StatelessWidget {
  const PaymentPreviewScreen({super.key});

  @override
  Widget build(BuildContext context) => AppPage(
    title: 'Payment screens',
    children: [
      const NoticeCard(
        icon: Icons.visibility_outlined,
        title: 'Design preview',
        lines: [
          'These are examples of what you would see. No payment is being made.',
        ],
      ),
      for (final v in PaymentView.values) ...[
        const SizedBox(height: AppSpace.lg),
        SectionLabel('Example · ${v.name}'),
        const SizedBox(height: AppSpace.sm),
        PaymentStateCard(v, amount: '₹100'),
      ],
    ],
  );
}
