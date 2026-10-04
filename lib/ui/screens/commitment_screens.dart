import 'package:flutter/material.dart';

import '../../core/commitment.dart';
import '../../core/commitment_engine.dart';
import '../../core/features.dart';
import '../../core/payment.dart';
import '../format.dart';
import '../widgets.dart';
import 'create_flow.dart';
import 'emergency.dart';
import 'end_challenge.dart';
import 'welcome_home.dart';

/// Only when a payment was confirmed for a challenge that also reached its
/// end time. Says only what is on record. Null in the normal case.
String? _latePaymentLine(Commitment c) {
  final amount = formatAmount(c.commitmentAmount);
  final p = c.payment;
  if (p == null || p.status != PaymentStatus.successful) return null;
  return switch (p.refund) {
    RefundStatus.refunded => 'Your $amount payment has been refunded.',
    RefundStatus.pending => 'Your $amount payment is being refunded.',
    RefundStatus.failed =>
      'The refund of your $amount payment did not go through. Please contact support.',
    RefundStatus.none =>
      'A payment of $amount was confirmed after this challenge had already ended.',
  };
}

String _refundLabel(RefundStatus r) => switch (r) {
  RefundStatus.none => 'None',
  RefundStatus.pending => 'In progress',
  RefundStatus.refunded => 'Refunded',
  RefundStatus.failed => 'Did not go through',
};

/// Money is only ever mentioned when the release has payments switched on.
bool _money(Commitment c) => Features.payments && c.commitmentAmount > 0;

String _times(int n) => n == 1 ? 'once' : '$n times';

/// Emergency access button, shared by the challenge and blocked screens. It
/// only opens a confirmation, so it cannot be used by accident.
class _EmergencyButton extends StatelessWidget {
  const _EmergencyButton(this.c);
  final Commitment c;

  @override
  Widget build(BuildContext context) {
    final inEmergency = c.status == CommitmentStatus.emergency;
    final left = c.emergencyRemaining;
    final String label;
    if (inEmergency) {
      label = 'Emergency access in use';
    } else if (left == 0) {
      label = 'No emergency access left';
    } else {
      label = 'Emergency access · $left left';
    }
    return SecondaryButton(
      label,
      onPressed: (inEmergency || left == 0)
          ? null
          : () => push(context, const EmergencyConfirmScreen()),
    );
  }
}

class _EndEarlyButton extends StatelessWidget {
  const _EndEarlyButton();

  @override
  Widget build(BuildContext context) => QuietButton(
    'End challenge early',
    onPressed: () => push(context, const EndChallengeConfirmScreen()),
  );
}

/// The two numbers that stay visible for the whole challenge.
class _KeyFacts extends StatelessWidget {
  const _KeyFacts(this.c);
  final Commitment c;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      if (_money(c)) ...[
        StatTile(
          label: 'Commitment Amount',
          value: formatAmount(c.commitmentAmount),
        ),
        const SizedBox(width: AppSpace.md),
      ],
      StatTile(label: 'Emergency access', value: emergencyLeft(c)),
    ],
  );
}

class _Gone extends StatelessWidget {
  const _Gone(this.text, {this.title});
  final String text;
  final String? title;

  @override
  Widget build(BuildContext context) => AppPage(
    title: title,
    centered: true,
    actions: [
      PrimaryButton(
        'Back to home',
        onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
      ),
    ],
    children: [Note(text, center: true)],
  );
}

/// The running challenge.
class ActiveCommitmentScreen extends StatelessWidget {
  const ActiveCommitmentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = CommitScope.of(context);
    final c = controller.active;
    if (c == null) {
      return const _Gone('There is no active challenge.', title: 'Challenge');
    }
    controller.ensureIcons();
    final now = controller.now;
    final inEmergency = c.status == CommitmentStatus.emergency;
    final interruptions = c.interruptionCount;
    return AppPage(
      title: 'Your challenge',
      actions: [
        PrimaryButton(
          'Back to home',
          onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
        ),
        if (c.emergencyLimit > 0) _EmergencyButton(c),
        if (_money(c)) const _EndEarlyButton(),
      ],
      children: [
        const ProtectionBanner(),
        if (controller.relockNotice) ...[
          NoticeCard(
            tone: Tone.brand,
            icon: Icons.lock_outline,
            title: 'Your apps are blocked again',
            lines: const ['Emergency access has ended.'],
            onDismiss: controller.dismissRelockNotice,
          ),
          const SizedBox(height: AppSpace.lg),
        ],
        Center(
          child: Text(
            inEmergency ? 'EMERGENCY ACCESS' : 'TIME REMAINING',
            style: AppText.label,
          ),
        ),
        const SizedBox(height: AppSpace.md),
        TimeRing(
          size: 200,
          tone: inEmergency ? Tone.warm : Tone.brand,
          progress: inEmergency
              ? emergencyProgress(c, now)
              : challengeProgress(c, now),
          time: inEmergency
              ? formatTimeLeft(CommitmentEngine.emergencyRemaining(c, now))
              : formatTimeLeft(CommitmentEngine.remaining(c, now)),
          caption: inEmergency ? 'then your apps lock again' : 'remaining',
        ),
        const SizedBox(height: AppSpace.lg),
        Text(
          inEmergency ? 'Your apps are open for now.' : "You're doing it.",
          textAlign: TextAlign.center,
          style: AppText.subheading,
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          inEmergency
              ? 'Your challenge has ${formatTimeLeft(CommitmentEngine.remaining(c, now))} left.'
              : 'Ends ${formatWhen(c.endTime)}',
          textAlign: TextAlign.center,
          style: AppText.bodyMuted,
        ),
        const SizedBox(height: AppSpace.xl),
        SectionLabel(inEmergency ? 'Tap an app to open it' : 'Protected apps'),
        const SizedBox(height: AppSpace.sm),
        AppPills(
          c.apps,
          onTap: inEmergency
              ? (a) => controller.bridge.launchApp(a.packageName)
              : null,
        ),
        const SizedBox(height: AppSpace.lg),
        _KeyFacts(c),
        if (interruptions > 0) ...[
          const SizedBox(height: AppSpace.lg),
          Note(
            'Protection was interrupted ${_times(interruptions)} during this challenge.',
            center: true,
          ),
        ],
        if (controller.missingApps.isNotEmpty) ...[
          const SizedBox(height: AppSpace.lg),
          Note(
            '${controller.missingApps.join(', ')} no longer installed. Your challenge continues until it ends.',
            center: true,
          ),
        ],
      ],
    );
  }
}

/// Shown when a protected app is opened during a challenge.
class BlockedScreen extends StatelessWidget {
  const BlockedScreen({super.key, this.relocked = false});

  /// True when this is the automatic re-lock after emergency access.
  final bool relocked;

  @override
  Widget build(BuildContext context) {
    final controller = CommitScope.of(context);
    final c = controller.active;
    if (c == null) return const _Gone('This challenge has ended.');
    final now = controller.now;
    final names = appsLabel(c.appNames);
    final plural = c.apps.length > 1;
    return AppPage(
      centered: true,
      actions: [
        PrimaryButton(
          'Back to challenge',
          onPressed: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => const ActiveCommitmentScreen(),
            ),
          ),
        ),
        if (c.emergencyLimit > 0) _EmergencyButton(c),
        if (_money(c)) const _EndEarlyButton(),
      ],
      children: [
        const ProtectionBanner(),
        Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: AppColors.brandSoft,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.lock_outline,
              size: 30,
              color: AppColors.brand,
            ),
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        Text(
          relocked ? 'Emergency access has ended.' : "You're in a challenge.",
          textAlign: TextAlign.center,
          style: AppText.heading,
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          '$names ${plural ? 'are' : 'is'} blocked for',
          textAlign: TextAlign.center,
          style: AppText.bodyMuted,
        ),
        const SizedBox(height: AppSpace.xs),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            formatTimeLeft(CommitmentEngine.remaining(c, now)),
            style: AppText.timer,
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        _KeyFacts(c),
        if (_money(c)) ...[
          const SizedBox(height: AppSpace.lg),
          const Note('Finish the challenge and you pay ₹0.', center: true),
        ],
      ],
    );
  }
}

/// Everything on record about one challenge (opened from History).
class DetailsScreen extends StatelessWidget {
  const DetailsScreen({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final c = CommitScope.of(context).byId(id);
    if (c == null) {
      return const _Gone(
        'This challenge is no longer available.',
        title: 'Details',
      );
    }
    final p = c.payment;
    final early = c.status == CommitmentStatus.endedEarly;
    return AppPage(
      title: 'Details',
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: StatusPill(resultLabel(c), tone: resultTone(c)),
        ),
        const SizedBox(height: AppSpace.md),
        Text(appsLabel(c.appNames), style: AppText.heading),
        const SizedBox(height: AppSpace.lg),
        const SectionLabel('Challenge'),
        const SizedBox(height: AppSpace.sm),
        SummaryCard(
          children: [
            InfoRow(c.apps.length == 1 ? 'App' : 'Apps', c.appNames.join('\n')),
            InfoRow('Duration', formatMinutes(c.durationMinutes)),
            InfoRow('Started', formatDateTime(c.startTime)),
            InfoRow(
              c.isLive ? 'Ends' : 'Planned end',
              formatDateTime(c.endTime),
            ),
            if (early && c.actualEndTime != null) ...[
              InfoRow('Ended', formatDateTime(c.actualEndTime!)),
              InfoRow('Time that was left', formatRemaining(c.remainingAtEnd)),
            ],
            InfoRow(
              'Emergency access',
              c.emergencyLimit == 0
                  ? 'None'
                  : '${c.emergencyAccessCount} of ${c.emergencyLimit} used',
            ),
            if (c.restored)
              const InfoRow('Restored', 'After Commit was removed or reset'),
            if (c.interruptionCount > 0)
              InfoRow(
                'Protection interrupted',
                '${_times(c.interruptionCount)} · ${formatRemaining(CommitmentEngine.interruptedTime(c, c.endTime))}',
              ),
          ],
        ),
        if (_money(c)) ...[
          const SizedBox(height: AppSpace.lg),
          const SectionLabel('Commitment Amount'),
          const SizedBox(height: AppSpace.sm),
          SummaryCard(
            children: [
              InfoRow('Commitment Amount', formatAmount(c.commitmentAmount)),
              InfoRow('Payment status', paymentLine(c)),
              if (p?.transactionId != null)
                InfoRow('Payment ID', p!.transactionId!),
              if (p?.paidAt != null)
                InfoRow('Paid on', formatDateTime(p!.paidAt!)),
              if (p != null && p.refund != RefundStatus.none)
                InfoRow('Refund', _refundLabel(p.refund)),
              if (c.consent != null)
                InfoRow('You agreed on', formatDateTime(c.consent!.acceptedAt)),
            ],
          ),
        ],
      ],
    );
  }
}

/// Colour for a finished challenge.
Tone resultTone(Commitment c) => switch (c.status) {
  CommitmentStatus.completed =>
    CommitmentEngine.keptCleanly(c) ? Tone.success : Tone.warm,
  CommitmentStatus.endedEarly => Tone.warm,
  CommitmentStatus.cancelled => Tone.neutral,
  _ => Tone.brand,
};

class CompletedScreen extends StatelessWidget {
  const CompletedScreen({super.key, required this.commitment});
  final Commitment commitment;

  @override
  Widget build(BuildContext context) {
    final c = commitment;
    final controller = CommitScope.of(context);
    final clean = CommitmentEngine.keptCleanly(c);
    final late = _latePaymentLine(c);

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
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: clean ? AppColors.successSoft : AppColors.warmSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(
              clean ? Icons.check : Icons.shield_outlined,
              size: 36,
              color: clean ? AppColors.success : AppColors.warm,
            ),
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        Text(
          clean ? 'Challenge complete 🎉' : 'Challenge period ended',
          textAlign: TextAlign.center,
          style: AppText.heading,
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          clean
              ? 'You kept your commitment.'
              : c.interruptionCount == 0
              ? 'Commit was removed or reset on this phone during this challenge and the challenge was restored afterwards, so it is not counted as fully kept.'
              : 'Protection was interrupted ${_times(c.interruptionCount)} during this challenge (about ${formatRemaining(CommitmentEngine.interruptedTime(c, c.endTime))} in total), so it is not counted as fully kept.',
          textAlign: TextAlign.center,
          style: AppText.bodyMuted,
        ),
        if (clean) ...[
          const SizedBox(height: AppSpace.xs),
          Text(
            '${formatLength(c.durationMinutes)} completed.',
            textAlign: TextAlign.center,
            style: AppText.title,
          ),
        ],
        const SizedBox(height: AppSpace.xl),
        SummaryCard(
          children: [
            InfoRow('Protected apps', c.appNames.join('\n')),
            if (!clean) InfoRow('Length', formatLength(c.durationMinutes)),
            if (c.emergencyLimit > 0)
              InfoRow(
                'Emergency access used',
                '${c.emergencyAccessCount} of ${c.emergencyLimit}',
              ),
            if (_money(c))
              InfoRow('Commitment Amount', formatAmount(c.commitmentAmount)),
            if (_money(c) && late == null)
              const InfoRow('Amount payable', '₹0'),
          ],
        ),
        if (late != null) ...[
          const SizedBox(height: AppSpace.lg),
          NoticeCard(icon: Icons.info_outline, title: late),
        ],
        if (clean) ...[
          const SizedBox(height: AppSpace.xl),
          Text(
            CommitmentEngine.messageFor(c),
            textAlign: TextAlign.center,
            style: AppText.title.copyWith(color: AppColors.brand),
          ),
        ],
      ],
    );
  }
}
