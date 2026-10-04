import 'package:flutter/material.dart';

import '../../core/features.dart';
import '../../core/commitment_engine.dart';
import '../format.dart';
import '../widgets.dart';
import 'commitment_screens.dart';

/// Explicit confirmation before one emergency access is used.
class EmergencyConfirmScreen extends StatefulWidget {
  const EmergencyConfirmScreen({super.key});

  @override
  State<EmergencyConfirmScreen> createState() => _EmergencyConfirmScreenState();
}

class _EmergencyConfirmScreenState extends State<EmergencyConfirmScreen> {
  bool _busy = false;

  Future<void> _start() async {
    if (_busy) return;
    setState(() => _busy = true);
    final controller = CommitScope.of(context);
    final nav = Navigator.of(context);
    try {
      await controller.startEmergency();
      nav.popUntil((r) => r.isFirst);
      nav.push(
        MaterialPageRoute<void>(builder: (_) => const ActiveCommitmentScreen()),
      );
    } on CommitmentException catch (e) {
      if (mounted) showMessage(context, e.error.message);
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          'Emergency access could not be started. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = CommitScope.of(context).active;
    if (c == null) {
      return const AppPage(
        title: 'Emergency access',
        centered: true,
        children: [Note('There is no active challenge.', center: true)],
      );
    }
    final left = c.emergencyRemaining;
    final after = left > 0 ? left - 1 : 0;
    return AppPage(
      title: 'Emergency access',
      actions: [
        PrimaryButton(
          _busy ? 'Starting…' : 'Use emergency access',
          onPressed: (_busy || left == 0) ? null : _start,
        ),
        QuietButton(
          'Not now',
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
      ],
      children: [
        const Text('Use emergency access?', style: AppText.heading),
        const SizedBox(height: AppSpace.sm),
        Text(
          'Your apps open for ${formatMinutes(c.emergencyMinutes)}, then lock again by themselves.',
          style: AppText.bodyMuted,
        ),
        const SizedBox(height: AppSpace.xl),
        SummaryCard(
          children: [
            if (Features.payments)
              const OutcomeRow(
                icon: Icons.check,
                when: 'Cost',
                result: 'Free. Nothing is charged.',
                tone: Tone.success,
              ),
            const OutcomeRow(
              icon: Icons.timer_outlined,
              when: 'Your challenge',
              result: 'This does not end your challenge.',
            ),
            OutcomeRow(
              icon: Icons.health_and_safety_outlined,
              when: 'Left after this',
              result: after == 0 ? 'None' : '$after of ${c.emergencyLimit}',
              tone: Tone.warm,
            ),
          ],
        ),
        if (left <= 1) ...[
          const SizedBox(height: AppSpace.lg),
          const Note(
            'This is your last one. After it, the apps stay blocked until the challenge ends.',
          ),
        ],
      ],
    );
  }
}
