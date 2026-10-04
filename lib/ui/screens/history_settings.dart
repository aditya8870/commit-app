import 'package:flutter/material.dart';

import '../../core/commitment.dart';
import '../../core/features.dart';
import '../format.dart';
import '../widgets.dart';
import 'commitment_screens.dart';
import 'create_flow.dart';
import 'end_challenge.dart';

/// The in-app privacy summary. It must describe what the app really does;
/// tests check it against the architecture.
const privacySummary =
    'No account is required: no name, email or phone number.\n\n'
    'Commit works with a server. When you first open it, this installation is '
    'registered under a random ID, with a scrambled (hashed) form of an '
    'Android device identifier and the app and Android version. The hashed '
    'identifier lets the same installation be recognised if you reinstall.\n\n'
    'When you start a challenge, Commit sends the server the apps you chose '
    'to block (their names), the length, your emergency access settings and '
    'the start and end time. During a challenge it also sends when emergency '
    'access was used and when protection was interrupted or restored. This '
    'keeps the challenge time honest and lets a challenge be restored after a '
    'reinstall. A copy is also kept on this phone.\n\n'
    'Everything is sent encrypted (HTTPS). There are no ads and no analytics, '
    'and the data is not sold or shared for advertising.\n\n'
    'Accessibility access and Usage access are used only to see which app is '
    'open, and Display over other apps only to show the blocked screen. Which '
    'app is open is used on your phone and is not sent. Commit cannot read '
    'your screen, messages, passwords or typing.\n\n'
    'Commit does not access your location, contacts, messages, photos, '
    'microphone or camera.';

/// One past challenge: what, how long, how it went, and what was payable.
class ChallengeTile extends StatelessWidget {
  const ChallengeTile(this.c, {super.key});
  final Commitment c;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => push(context, DetailsScreen(id: c.id)),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    appsLabel(c.appNames),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.title,
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                StatusPill(resultLabel(c), tone: resultTone(c)),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              '${formatLength(c.durationMinutes)} · ${formatWhen(c.startTime)}',
              style: AppText.small,
            ),
            if (Features.payments && c.commitmentAmount > 0) ...[
              const SizedBox(height: 2),
              Text(
                'Commitment Amount ${formatAmount(c.commitmentAmount)} · ${paymentLine(c)}',
                style: AppText.small.copyWith(
                  color: AppColors.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = CommitScope.of(context);
    final items = controller.history;
    final s = controller.stats;
    return AppPage(
      title: 'History',
      centered: items.isEmpty,
      children: [
        if (items.isEmpty) ...[
          const Icon(Icons.history, size: 48, color: AppColors.faint),
          const SizedBox(height: AppSpace.md),
          const Text(
            'No challenges yet',
            textAlign: TextAlign.center,
            style: AppText.subheading,
          ),
          const SizedBox(height: AppSpace.xs),
          const Note(
            'Your finished challenges will appear here.',
            center: true,
          ),
        ] else ...[
          Row(
            children: [
              StatTile(
                label: 'Completed',
                value: '${s.completed} of ${s.total}',
              ),
              const SizedBox(width: AppSpace.md),
              StatTile(label: 'Completion rate', value: '${s.completionRate}%'),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              if (Features.payments) ...[
                StatTile(label: 'Ended early', value: '${s.endedEarly}'),
                const SizedBox(width: AppSpace.md),
              ],
              StatTile(
                label: 'Emergency access used',
                value: '${s.emergencyUses}',
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xl),
          const SectionLabel('All challenges'),
          const SizedBox(height: AppSpace.sm),
          for (final c in items) ...[
            ChallengeTile(c),
            const SizedBox(height: AppSpace.sm),
          ],
        ],
      ],
    );
  }
}

/// The six things to understand before starting, in plain words.
class HowItWorksScreen extends StatelessWidget {
  const HowItWorksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final connected = CommitScope.of(context).payments.isConfigured;
    return AppPage(
      title: 'How Commit works',
      children: [
        const Text('Decide before temptation.', style: AppText.heading),
        const SizedBox(height: AppSpace.lg),
        const _Fact(
          'What you commit to',
          'Staying away from the apps you choose, for the time you choose.',
        ),
        if (Features.payments) ...[
          const _Fact(
            'The Commitment Amount',
            'An amount you pick yourself before the challenge starts. It never changes during a challenge.',
          ),
          const _Fact(
            'What makes it payable',
            'Only one thing: you choose "End challenge early", see the amount, and confirm.',
          ),
          const _Fact(
            'What never costs anything',
            'Completing the challenge. Emergency access. Your phone restarting, the app closing, a lost connection or a switched-off permission.',
          ),
          const _Fact(
            'Emergency access',
            'A short, free unlock you allow yourself in advance. The apps lock again by themselves and your challenge continues.',
          ),
          const _Fact(
            'When you complete a challenge',
            'Your apps unlock and the amount payable is ₹0.',
          ),
          if (!connected) ...[
            const SizedBox(height: AppSpace.sm),
            const NoticeCard(
              icon: Icons.construction,
              title: 'Test version',
              lines: [
                'Payments are not connected, so nothing can be charged and a challenge cannot be ended early yet.',
              ],
            ),
          ],
        ] else ...[
          const _Fact(
            'While a challenge runs',
            'Those apps are covered by the Commit screen whenever you open them. A challenge cannot be shortened once it starts.',
          ),
          const _Fact(
            'Emergency access',
            'A short unlock you allow yourself in advance. The apps lock again by themselves and your challenge continues.',
          ),
          const _Fact(
            'When you complete a challenge',
            'Your apps unlock by themselves at the end time.',
          ),
          const _Fact(
            'If protection is interrupted',
            'If blocking is switched off, or Commit is removed or reset during a challenge, that is recorded and the challenge is not counted as fully kept.',
          ),
          const _Fact(
            'Money',
            'Commit is free. This version never charges you anything.',
          ),
        ],
        const SizedBox(height: AppSpace.lg),
        const Note(
          'Commit makes giving in harder, not impossible. Android always leaves you in control of your phone: switching off its permissions removes the protection.',
        ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.title, this.body);
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.md),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: AppText.title),
            const SizedBox(height: AppSpace.xs),
            Text(body, style: AppText.bodyMuted),
          ],
        ),
      ),
    ),
  );
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Future<String>? _version;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _version ??= CommitScope.of(context).bridge.appVersion();
  }

  void _info(String title, String body) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(body, style: AppText.body)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body, style: AppText.body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _reset() async {
    final controller = CommitScope.of(context);
    if (!await _confirm(
      'Delete your history?',
      'Past challenges and statistics will be removed from this phone.',
    )) {
      return;
    }
    if (controller.active != null) {
      if (!mounted) return;
      if (!await _confirm(
        'You have a challenge running',
        'It will be kept and stays blocked until it ends. Only past history will be deleted.',
      )) {
        return;
      }
    }
    try {
      await controller.resetData();
      if (mounted) showMessage(context, 'History deleted.');
    } catch (_) {
      if (mounted) showMessage(context, 'History could not be deleted.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = CommitScope.of(context);
    final on = controller.protectionEnabled;
    return AppPage(
      title: 'Settings',
      children: [
        const SectionLabel('Protection'),
        const SizedBox(height: AppSpace.sm),
        _Group([
          _Item(
            icon: on ? Icons.verified_user_outlined : Icons.gpp_maybe_outlined,
            tone: on ? Tone.brand : Tone.warm,
            title: 'Blocking setup',
            subtitle: on
                ? protectionSummary(controller)
                : 'Blocking is off. Tap to set it up.',
            onTap: () => push(context, const PermissionScreen()),
          ),
        ]),
        const SizedBox(height: AppSpace.xl),
        const SectionLabel('About'),
        const SizedBox(height: AppSpace.sm),
        _Group([
          _Item(
            icon: Icons.help_outline,
            title: 'How Commit works',
            subtitle: Features.payments
                ? 'What costs money and what never does'
                : 'A short guide',
            onTap: () => push(context, const HowItWorksScreen()),
          ),
          _Item(
            icon: Icons.lock_outline,
            title: 'Privacy',
            subtitle: 'What Commit stores and sends',
            onTap: () => _info('Privacy', privacySummary),
          ),
          if (Features.privacyPolicyUrl.isNotEmpty)
            _Item(
              icon: Icons.description_outlined,
              title: 'Privacy policy',
              subtitle: 'Opens in your browser',
              onTap: () => controller.bridge.openUrl(Features.privacyPolicyUrl),
            ),
          if (Features.payments)
            _Item(
              icon: Icons.payments_outlined,
              title: 'Payment screens',
              subtitle: controller.payments.isConfigured
                  ? 'Preview of every payment state'
                  : 'Preview only. Payments are not connected.',
              onTap: () => push(context, const PaymentPreviewScreen()),
            ),
        ]),
        const SizedBox(height: AppSpace.xl),
        const SectionLabel('Data'),
        const SizedBox(height: AppSpace.sm),
        _Group([
          _Item(
            icon: Icons.delete_outline,
            title: 'Reset local data',
            subtitle: 'Delete your challenge history from this phone',
            onTap: _reset,
          ),
        ]),
        const SizedBox(height: AppSpace.xl),
        FutureBuilder<String>(
          future: _version,
          builder: (context, snap) =>
              Note('Commit ${snap.data ?? ''}'.trim(), center: true),
        ),
      ],
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.items);
  final List<Widget> items;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 64),
          items[i],
        ],
      ],
    ),
  );
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tone = Tone.brand,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Tone tone;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(
      horizontal: AppSpace.lg,
      vertical: AppSpace.xs,
    ),
    leading: Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: tone.soft, shape: BoxShape.circle),
      child: Icon(icon, size: 20, color: tone.strong),
    ),
    title: Text(title, style: AppText.title),
    subtitle: Text(subtitle, style: AppText.small),
    trailing: const Icon(Icons.chevron_right, color: AppColors.faint),
    onTap: onTap,
  );
}
