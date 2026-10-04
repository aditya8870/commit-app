import 'package:flutter/material.dart';

import '../../core/commitment.dart';
import '../../core/commitment_engine.dart';
import '../../core/features.dart';
import '../format.dart';
import '../widgets.dart';
import 'commitment_screens.dart';
import 'create_flow.dart';
import 'history_settings.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  bool _busy = false;

  Future<void> _start() async {
    if (_busy) return;
    setState(() => _busy = true);
    final c = CommitScope.of(context);
    final nav = Navigator.of(context);
    await c.completeOnboarding();
    // Go straight into setup so the first challenge works first time.
    if (!c.fullProtection) {
      nav.push(
        MaterialPageRoute<void>(builder: (_) => const PermissionScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppPage(
      centered: true,
      actions: [PrimaryButton('Get started', onPressed: _busy ? null : _start)],
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.brandSoft,
              borderRadius: BorderRadius.circular(AppRadius.card),
            ),
            child: const Icon(
              Icons.lock_outline,
              size: 32,
              color: AppColors.brand,
            ),
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        Text(
          'Decide before temptation.',
          style: AppText.heading.copyWith(fontSize: 34),
        ),
        const SizedBox(height: AppSpace.md),
        const Text(
          'Commit keeps distracting apps closed for as long as you decide.',
          style: AppText.bodyMuted,
        ),
        const SizedBox(height: AppSpace.xl),
        SummaryCard(
          children: [
            const OutcomeRow(
              icon: Icons.apps,
              when: 'First',
              result: 'Choose the apps and how long',
            ),
            if (Features.payments)
              const OutcomeRow(
                icon: Icons.currency_rupee,
                when: 'Then',
                result: 'Set a Commitment Amount',
              )
            else
              const OutcomeRow(
                icon: Icons.lock_outline,
                when: 'Then',
                result: 'They stay blocked until the time is up',
              ),
            OutcomeRow(
              icon: Icons.check,
              when: 'Finish the challenge',
              result: Features.payments ? 'You pay ₹0' : 'Your apps unlock',
              tone: Tone.success,
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        const Note('No account required. No name, email or phone number.'),
      ],
    );
  }
}

/// Colour for a challenge state pill.
Tone toneFor(ChallengeState s) => switch (s) {
  ChallengeState.active => Tone.brand,
  ChallengeState.completed => Tone.success,
  ChallengeState.emergency ||
  ChallengeState.protectionInterrupted ||
  ChallengeState.paymentPending => Tone.warm,
  _ => Tone.neutral,
};

/// 0..1: how far through the challenge we are.
double challengeProgress(Commitment c, DateTime now) {
  final total = c.endTime.difference(c.startTime).inSeconds;
  if (total <= 0) return 1;
  return now.difference(c.startTime).inSeconds / total;
}

/// 0..1: how much of the current emergency access has been used.
double emergencyProgress(Commitment c, DateTime now) {
  final total = c.emergencyMinutes * 60;
  if (total <= 0) return 1;
  return 1 - CommitmentEngine.emergencyRemaining(c, now).inSeconds / total;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = CommitScope.of(context);
    final warning = c.loadWarning ?? c.notice;
    if (warning != null) {
      c.clearLoadWarning();
      c.notice = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showMessage(context, warning);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = CommitScope.of(context);
    final active = c.active;
    if (active != null) c.ensureIcons();
    final inEmergency = active?.status == CommitmentStatus.emergency;
    return Scaffold(
      body: Column(
        children: [
          _Hero(
            title: active == null
                ? 'Ready for a fresh start?'
                : inEmergency
                ? 'Emergency access is on.'
                : "You're doing great.",
            subtitle: active == null
                ? 'Choose what you want to focus on today.'
                : inEmergency
                ? 'Your apps lock again soon.'
                : 'Stay focused on your goal.',
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpace.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ProtectionBanner(),
                  if (active == null)
                    _StartCard(completed: c.stats.completed)
                  else
                    _ActiveCard(active),
                  const SizedBox(height: AppSpace.xl),
                  const SectionLabel('Explore'),
                  const SizedBox(height: AppSpace.sm),
                  _Explore(challengeRunning: active != null),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Coloured top of Home: the app name and one encouraging line.
class _Hero extends StatelessWidget {
  const _Hero({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    decoration: const BoxDecoration(
      color: AppColors.brand,
      borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
    ),
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.xl,
          AppSpace.xl,
          AppSpace.xl,
          AppSpace.xl + 4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'COMMIT',
              style: AppText.label.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: AppSpace.lg),
            Text(
              title,
              style: AppText.heading.copyWith(
                color: Colors.white,
                fontSize: 30,
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(subtitle, style: AppText.body.copyWith(color: Colors.white70)),
          ],
        ),
      ),
    ),
  );
}

/// Home when nothing is running: a welcome and one button.
class _StartCard extends StatelessWidget {
  const _StartCard({required this.completed});
  final int completed;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(
                  color: AppColors.brandSoft,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.spa_outlined, color: AppColors.brand),
              ),
              const SizedBox(width: AppSpace.lg),
              const Expanded(
                child: Text('No active challenge', style: AppText.subheading),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            completed == 0
                ? 'Pick the apps that distract you and how long you want a break from them.'
                : completed == 1
                ? 'You have completed 1 challenge. Ready for the next one?'
                : 'You have completed $completed challenges. Ready for the next one?',
            style: AppText.bodyMuted,
          ),
          const SizedBox(height: AppSpace.xl),
          PrimaryButton(
            'Start a challenge',
            onPressed: () => startCommitmentFlow(context),
          ),
        ],
      ),
    ),
  );
}

/// Home while a challenge is running: apps, time left, progress, one button.
class _ActiveCard extends StatelessWidget {
  const _ActiveCard(this.c);
  final Commitment c;

  @override
  Widget build(BuildContext context) {
    final controller = CommitScope.of(context);
    final inEmergency = c.status == CommitmentStatus.emergency;
    final now = controller.now;
    final state = controller.activeState ?? ChallengeState.active;
    final tone = inEmergency ? Tone.warm : Tone.brand;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Your challenge', style: AppText.title),
                ),
                StatusPill(state.label, tone: toneFor(state)),
              ],
            ),
            const SizedBox(height: AppSpace.lg),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                inEmergency
                    ? '${formatTimeLeft(CommitmentEngine.emergencyRemaining(c, now))} of access left'
                    : formatRemainingSentence(
                        CommitmentEngine.remaining(c, now),
                      ),
                style: AppText.heading.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: challengeProgress(c, now).clamp(0.0, 1.0),
                minHeight: 8,
                color: tone.strong,
                backgroundColor: tone.soft,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Text('Ends ${formatWhen(c.endTime)}', style: AppText.small),
            const SizedBox(height: AppSpace.lg),
            AppPills(c.apps),
            const SizedBox(height: AppSpace.xl),
            PrimaryButton(
              'Continue challenge',
              onPressed: () => push(context, const ActiveCommitmentScreen()),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rest of the app, always reachable from Home.
class _Explore extends StatelessWidget {
  const _Explore({required this.challengeRunning});
  final bool challengeRunning;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      _ExploreRow(
        icon: Icons.history,
        title: 'History',
        subtitle: 'Your past challenges',
        onTap: () => push(context, const HistoryScreen()),
      ),
      _ExploreRow(
        icon: Icons.help_outline,
        title: 'How Commit works',
        subtitle: 'A short guide',
        onTap: () => push(context, const HowItWorksScreen()),
      ),
      _ExploreRow(
        icon: Icons.settings_outlined,
        title: 'Settings',
        subtitle: 'Blocking setup and privacy',
        onTap: () => push(context, const SettingsScreen()),
      ),
      if (challengeRunning)
        _ExploreRow(
          icon: Icons.add_circle_outline,
          title: 'New challenge',
          subtitle: 'Available when this one ends',
          muted: true,
          onTap: () => startCommitmentFlow(context),
        ),
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 64),
            rows[i],
          ],
        ],
      ),
    );
  }
}

class _ExploreRow extends StatelessWidget {
  const _ExploreRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.muted = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool muted;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
    leading: Icon(icon, color: muted ? AppColors.faint : AppColors.brand),
    title: Text(
      title,
      style: AppText.title.copyWith(
        fontSize: 16,
        color: muted ? AppColors.muted : AppColors.ink,
      ),
    ),
    subtitle: Text(subtitle, style: AppText.small),
    trailing: const Icon(Icons.chevron_right, color: AppColors.faint),
    onTap: onTap,
  );
}
