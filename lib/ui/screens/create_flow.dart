import 'package:flutter/material.dart';

import '../../core/commitment.dart';
import '../../core/commitment_engine.dart';
import '../../core/features.dart';
import '../../platform/platform_bridge.dart';
import '../format.dart';
import '../widgets.dart';
import 'commitment_screens.dart';

/// Entry point for "Start a challenge".
void startCommitmentFlow(BuildContext context) {
  final c = CommitScope.of(context);
  if (c.active != null) {
    push(context, const ChallengeInProgressScreen());
    return;
  }
  push(
    context,
    c.readyToStart
        ? const SelectAppsScreen()
        : const PermissionScreen(continueToFlow: true),
  );
}

/// Shown instead of the creation flow while a challenge is running. Only
/// one challenge can be active at a time.
class ChallengeInProgressScreen extends StatelessWidget {
  const ChallengeInProgressScreen({super.key});

  @override
  Widget build(BuildContext context) => AppPage(
    title: 'New challenge',
    centered: true,
    actions: [
      PrimaryButton(
        'Open challenge',
        onPressed: () => Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => const ActiveCommitmentScreen(),
          ),
        ),
      ),
      QuietButton('Back', onPressed: () => Navigator.of(context).pop()),
    ],
    children: [
      Center(
        child: Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
            color: AppColors.brandSoft,
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.hourglass_top,
            size: 34,
            color: AppColors.brand,
          ),
        ),
      ),
      const SizedBox(height: AppSpace.lg),
      const Text(
        'You already have a challenge in progress.',
        textAlign: TextAlign.center,
        style: AppText.heading,
      ),
      const SizedBox(height: AppSpace.sm),
      const Text(
        'Finish your current challenge before starting a new one.',
        textAlign: TextAlign.center,
        style: AppText.bodyMuted,
      ),
    ],
  );
}

/// Explains what Commit needs from Android and shows what is switched on.
class PermissionScreen extends StatelessWidget {
  const PermissionScreen({super.key, this.continueToFlow = false});

  /// True when opened from "Start a challenge": Continue goes on to step 1.
  final bool continueToFlow;

  /// Accessibility is never opened before the user has read the disclosure
  /// and tapped "Agree".
  static void _accessibility(BuildContext context) {
    final c = CommitScope.of(context);
    if (c.accessibilityConsent) {
      c.bridge.openAccessibilitySettings();
    } else {
      push(context, const AccessibilityDisclosureScreen());
    }
  }

  void _openNextMissing(BuildContext context) {
    final c = CommitScope.of(context);
    if (!c.accessibilityEnabled) {
      _accessibility(context);
    } else if (!c.usageAccessEnabled) {
      c.bridge.openUsageAccessSettings();
    } else if (!c.overlayEnabled) {
      c.bridge.openOverlaySettings();
    } else {
      c.bridge.openBatterySettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = CommitScope.of(context);
    final enabled = c.readyToStart;
    final complete = c.fullProtection && c.batteryUnrestricted;
    final done = [
      c.accessibilityEnabled,
      c.usageAccessEnabled,
      c.overlayEnabled,
      c.batteryUnrestricted,
    ].where((v) => v).length;
    return AppPage(
      title: 'Set up blocking',
      actions: [
        if (!complete && !enabled)
          PrimaryButton(
            'Turn on next step',
            onPressed: () => _openNextMissing(context),
          ),
        if (enabled)
          PrimaryButton(
            continueToFlow ? 'Continue' : 'Done',
            onPressed: () => continueToFlow
                ? Navigator.of(context).pushReplacement(
                    MaterialPageRoute<void>(
                      builder: (_) => const SelectAppsScreen(),
                    ),
                  )
                : Navigator.of(context).pop(),
          ),
        if (!complete && enabled)
          SecondaryButton(
            'Turn on next step',
            onPressed: () => _openNextMissing(context),
          ),
      ],
      children: [
        Text(
          complete
              ? 'Everything is switched on.'
              : enabled
              ? 'You can start. A few extras are still off.'
              : 'Blocking permission required.',
          style: AppText.heading.copyWith(fontSize: 24),
        ),
        const SizedBox(height: AppSpace.sm),
        Text('$done of 4 switched on', style: AppText.bodyMuted),
        const SizedBox(height: AppSpace.lg),
        const SectionLabel('Needed to start'),
        const SizedBox(height: AppSpace.sm),
        _PermissionRow(
          title: 'Accessibility',
          detail: 'Blocks an app the moment it opens.',
          granted: c.accessibilityEnabled,
          onTap: () => _accessibility(context),
        ),
        const SizedBox(height: AppSpace.lg),
        const SectionLabel('Backup, recommended'),
        const SizedBox(height: AppSpace.sm),
        _PermissionRow(
          title: 'Usage access',
          detail: 'Keeps blocking if Accessibility is switched off.',
          granted: c.usageAccessEnabled,
          onTap: c.bridge.openUsageAccessSettings,
        ),
        const SizedBox(height: AppSpace.sm),
        _PermissionRow(
          title: 'Display over other apps',
          detail: 'Lets the backup show the blocked screen.',
          granted: c.overlayEnabled,
          onTap: c.bridge.openOverlaySettings,
        ),
        const SizedBox(height: AppSpace.sm),
        _PermissionRow(
          title: 'Battery: no restrictions',
          detail: 'Stops your phone closing Commit in the background.',
          granted: c.batteryUnrestricted,
          onTap: c.bridge.openBatterySettings,
        ),
        const SizedBox(height: AppSpace.lg),
        const NoticeCard(
          tone: Tone.brand,
          icon: Icons.lock_outline,
          title: 'What Commit can see',
          lines: [
            'Commit uses Accessibility access only to notice when an app you chose to block is opened, so it can cover it.',
            'It cannot read your screen, messages, passwords or typing.',
            'You stay in control: you can switch any of these off in Android Settings at any time.',
          ],
        ),
        if (!complete) ...[
          const SizedBox(height: AppSpace.lg),
          const Note(
            'Tap a step, switch it on for Commit, then come back. Accessibility is usually under "Installed apps" or "Downloaded apps".',
          ),
          const SizedBox(height: AppSpace.sm),
          const Note(
            'If your phone says the setting is restricted: open Settings → Apps → Commit, tap ⋮ and choose "Allow restricted settings", then try again.',
          ),
        ],
      ],
    );
  }
}

/// Shown before Commit ever sends the user to Android's Accessibility
/// settings: what the access is, what is read, what is not, and what is
/// stored or sent. Nothing happens unless the user taps "Agree".
class AccessibilityDisclosureScreen extends StatelessWidget {
  const AccessibilityDisclosureScreen({super.key});

  static const title = 'Commit needs Accessibility access to block apps';
  static const purpose =
      "Commit uses Android's Accessibility service for one purpose: to notice when an app you chose to block is opened, so it can cover it with the Commit screen straight away.";
  static const reads =
      'The name of the app that is open on your screen. Only while a challenge is running.';
  static const neverReads =
      'Anything on your screen, your messages, your passwords, or what you type.';
  static const storedOrSent =
      'The name of the open app is used on your phone at that moment. It is not saved and not sent anywhere. If Accessibility is switched off during a challenge, Commit records that this happened and sends that record to its server with your challenge.';
  static const control =
      'Commit is not an accessibility tool for people with disabilities. You can switch this access off at any time in Android Settings → Accessibility.';

  @override
  Widget build(BuildContext context) {
    final c = CommitScope.of(context);
    return AppPage(
      title: 'Accessibility access',
      actions: [
        PrimaryButton(
          'Agree',
          onPressed: () async {
            final nav = Navigator.of(context);
            await c.acceptAccessibilityDisclosure();
            nav.pop();
            await c.bridge.openAccessibilitySettings();
          },
        ),
        QuietButton('No thanks', onPressed: () => Navigator.of(context).pop()),
      ],
      children: const [
        Text(title, style: AppText.heading),
        SizedBox(height: AppSpace.md),
        Text(purpose, style: AppText.body),
        SizedBox(height: AppSpace.lg),
        _Disclosure('What Commit reads', reads),
        _Disclosure('What Commit does not read', neverReads),
        _Disclosure('What is stored or sent', storedOrSent),
        SizedBox(height: AppSpace.sm),
        Note(control),
      ],
    );
  }
}

class _Disclosure extends StatelessWidget {
  const _Disclosure(this.heading, this.text);
  final String heading;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.lg),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(heading, style: AppText.title),
        const SizedBox(height: AppSpace.xs),
        Text(text, style: AppText.bodyMuted),
      ],
    ),
  );
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.title,
    required this.detail,
    required this.granted,
    required this.onTap,
  });
  final String title;
  final String detail;
  final bool granted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    clipBehavior: Clip.antiAlias,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.xs,
      ),
      onTap: granted ? null : onTap,
      leading: Icon(
        granted ? Icons.check_circle : Icons.radio_button_unchecked,
        color: granted ? AppColors.success : AppColors.warm,
      ),
      title: Text(title, style: AppText.title),
      subtitle: Text(granted ? 'On' : detail, style: AppText.small),
      trailing: granted
          ? null
          : const Text(
              'Turn on',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.brand,
              ),
            ),
    ),
  );
}

/// What the user has chosen so far while creating a challenge.
class CommitmentDraft {
  final List<AppInfo> apps = [];
  int? minutes;
  int emergencyLimit = 1;
  int emergencyMinutes = CommitmentEngine.defaultEmergencyMinutes;
  int? amount;
}

// ------------------------------------------------------------ Step 1: apps

class SelectAppsScreen extends StatefulWidget {
  const SelectAppsScreen({super.key});

  @override
  State<SelectAppsScreen> createState() => _SelectAppsScreenState();
}

class _SelectAppsScreenState extends State<SelectAppsScreen> {
  final _draft = CommitmentDraft();
  Future<List<AppInfo>>? _apps;
  String _query = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _apps ??= CommitScope.of(context).bridge.installedApps();
  }

  void _retry() =>
      setState(() => _apps = CommitScope.of(context).bridge.installedApps());

  bool _isSelected(AppInfo a) =>
      _draft.apps.any((x) => x.packageName == a.packageName);

  void _toggle(AppInfo a) => setState(() {
    if (_isSelected(a)) {
      _draft.apps.removeWhere((x) => x.packageName == a.packageName);
    } else {
      _draft.apps.add(a);
    }
  });

  @override
  Widget build(BuildContext context) {
    final n = _draft.apps.length;
    return Scaffold(
      appBar: AppBar(title: const Text('New challenge')),
      body: SafeArea(
        child: FutureBuilder<List<AppInfo>>(
          future: _apps,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _Empty(
                text: 'Your apps could not be loaded.',
                onRetry: _retry,
              );
            }
            final all = snap.data ?? const <AppInfo>[];
            if (all.isEmpty) {
              return _Empty(
                text: 'No apps that can be blocked were found on this phone.',
                onRetry: _retry,
              );
            }
            final q = _query.trim().toLowerCase();
            final apps = q.isEmpty
                ? all
                : all
                      .where((a) => a.appName.toLowerCase().contains(q))
                      .toList();
            return Column(
              children: [
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                            AppSpace.xl,
                            AppSpace.lg,
                            AppSpace.xl,
                            AppSpace.sm,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const StepHeader(
                                step: 1,
                                question:
                                    'Which apps do you want to stay away from?',
                                why: 'Only these apps are blocked. Everything else works as usual.',
                              ),
                              const SizedBox(height: AppSpace.lg),
                              TextField(
                                onChanged: (v) => setState(() => _query = v),
                                decoration: InputDecoration(
                                  hintText: 'Search apps',
                                  prefixIcon: const Icon(Icons.search),
                                  filled: true,
                                  fillColor: AppColors.card,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: AppSpace.md,
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.button,
                                    ),
                                    borderSide: const BorderSide(
                                      color: AppColors.line,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.button,
                                    ),
                                    borderSide: const BorderSide(
                                      color: AppColors.brand,
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (apps.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(
                            child: Note('No apps match your search.'),
                          ),
                        )
                      else
                        SliverList.builder(
                          itemCount: apps.length,
                          itemBuilder: (context, i) {
                            final app = apps[i];
                            final on = _isSelected(app);
                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: AppSpace.xl,
                                vertical: 2,
                              ),
                              selected: on,
                              selectedTileColor: AppColors.brandSoft,
                              leading: AppIcon(
                                packageName: app.packageName,
                                appName: app.appName,
                                bytes: app.icon,
                                size: 44,
                              ),
                              title: Text(app.appName, style: AppText.title),
                              trailing: Icon(
                                on ? Icons.check_circle : Icons.circle_outlined,
                                size: 28,
                                color: on ? AppColors.brand : AppColors.faint,
                              ),
                              onTap: () => _toggle(app),
                            );
                          },
                        ),
                    ],
                  ),
                ),
                ActionBar(
                  children: [
                    if (n > 0)
                      Text(
                        appsLabel([for (final a in _draft.apps) a.appName]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: AppText.small,
                      ),
                    PrimaryButton(
                      n == 0
                          ? 'Choose at least one app'
                          : 'Continue · ${n == 1 ? '1 app' : '$n apps'}',
                      onPressed: n == 0
                          ? null
                          : () => push(
                              context,
                              SelectDurationScreen(draft: _draft),
                            ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text, required this.onRetry});
  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.xxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, textAlign: TextAlign.center, style: AppText.body),
          const SizedBox(height: AppSpace.lg),
          SecondaryButton('Try again', onPressed: onRetry),
        ],
      ),
    ),
  );
}

// -------------------------------------------------------- Step 2: duration

class SelectDurationScreen extends StatefulWidget {
  const SelectDurationScreen({super.key, required this.draft});
  final CommitmentDraft draft;

  @override
  State<SelectDurationScreen> createState() => _SelectDurationScreenState();
}

class _SelectDurationScreenState extends State<SelectDurationScreen> {
  static const _presets = [
    ...CommitmentEngine.shortDurations,
    ...CommitmentEngine.hourDurations,
    ...CommitmentEngine.dayDurations,
  ];

  void _pick(int minutes) => setState(() => widget.draft.minutes = minutes);

  Future<void> _custom() async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => const _CustomDurationDialog(),
    );
    if (minutes != null) _pick(minutes);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.draft.minutes;
    final isCustom = m != null && !_presets.contains(m);
    final until = m == null
        ? null
        : CommitScope.of(context).now.add(Duration(minutes: m));
    return StepPage(
      step: 2,
      question: 'How long do you want your challenge to last?',
      why: 'The apps stay blocked for this long. It cannot be shortened later.',
      actions: [
        if (until != null)
          Text(
            'Ends ${formatWhen(until)}',
            textAlign: TextAlign.center,
            style: AppText.small,
          ),
        PrimaryButton(
          'Continue',
          onPressed: m == null
              ? null
              : () => push(context, SelectEmergencyScreen(draft: widget.draft)),
        ),
      ],
      children: [
        ChipGroup<int>(
          title: 'Minutes',
          values: CommitmentEngine.shortDurations,
          label: formatChip,
          selected: m,
          onSelected: _pick,
        ),
        const SizedBox(height: AppSpace.xl),
        ChipGroup<int>(
          title: 'Hours',
          values: CommitmentEngine.hourDurations,
          label: formatChip,
          selected: m,
          onSelected: _pick,
        ),
        const SizedBox(height: AppSpace.xl),
        ChipGroup<int>(
          title: 'Days',
          values: CommitmentEngine.dayDurations,
          label: formatChip,
          selected: m,
          onSelected: _pick,
        ),
        const SizedBox(height: AppSpace.xl),
        Align(
          alignment: Alignment.centerLeft,
          child: OptionChip(
            label: isCustom ? 'Custom: ${formatMinutes(m)}' : 'Custom duration',
            selected: isCustom,
            onTap: _custom,
          ),
        ),
      ],
    );
  }
}

/// Number + unit. Returns the duration in minutes, or null if cancelled.
class _CustomDurationDialog extends StatefulWidget {
  const _CustomDurationDialog();

  @override
  State<_CustomDurationDialog> createState() => _CustomDurationDialogState();
}

class _CustomDurationDialogState extends State<_CustomDurationDialog> {
  static const _units = {'Minutes': 1, 'Hours': 60, 'Days': 1440};
  String _text = '';
  String _unit = 'Minutes';

  int? get _minutes {
    final n = int.tryParse(_text.trim());
    if (n == null || n <= 0 || n > CommitmentEngine.maxDurationMinutes) {
      return null;
    }
    final total = n * _units[_unit]!;
    if (total < CommitmentEngine.minDurationMinutes ||
        total > CommitmentEngine.maxDurationMinutes) {
      return null;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final minutes = _minutes;
    return AlertDialog(
      title: const Text('Custom duration'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              autofocus: true,
              keyboardType: TextInputType.number,
              style: AppText.subheading,
              decoration: const InputDecoration(hintText: 'Number'),
              onChanged: (v) => setState(() => _text = v),
            ),
            const SizedBox(height: AppSpace.lg),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                for (final u in _units.keys)
                  OptionChip(
                    label: u,
                    selected: _unit == u,
                    onTap: () => setState(() => _unit = u),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            Note(
              minutes != null
                  ? 'Blocked for ${formatMinutes(minutes)}.'
                  : 'Enter a whole number, up to 30 days in total.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: minutes == null
              ? null
              : () => Navigator.of(context).pop(minutes),
          child: const Text('Set'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------- Step 3: emergency

class SelectEmergencyScreen extends StatefulWidget {
  const SelectEmergencyScreen({super.key, required this.draft});
  final CommitmentDraft draft;

  @override
  State<SelectEmergencyScreen> createState() => _SelectEmergencyScreenState();
}

class _SelectEmergencyScreenState extends State<SelectEmergencyScreen> {
  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    return StepPage(
      step: 3,
      question: 'Allow emergency access?',
      why: 'A short unlock for when you really need an app. Decide now, while you are thinking clearly.',
      actions: [
        PrimaryButton(
          'Continue',
          onPressed: () => push(
            context,
            Features.payments
                ? SelectAmountScreen(draft: d)
                : ReviewScreen(draft: d),
          ),
        ),
      ],
      children: [
        ChipGroup<int>(
          title: 'How many times',
          values: CommitmentEngine.emergencyLimits,
          label: (n) => n == 0 ? 'None' : formatEmergencyLimit(n),
          selected: d.emergencyLimit,
          onSelected: (n) => setState(() => d.emergencyLimit = n),
        ),
        if (d.emergencyLimit > 0) ...[
          const SizedBox(height: AppSpace.xl),
          ChipGroup<int>(
            title: 'How long each time',
            values: CommitmentEngine.emergencyDurationsMinutes,
            label: formatChip,
            selected: d.emergencyMinutes,
            onSelected: (m) => setState(() => d.emergencyMinutes = m),
          ),
        ],
        const SizedBox(height: AppSpace.xl),
        NoticeCard(
          tone: Tone.brand,
          icon: Icons.health_and_safety_outlined,
          title: d.emergencyLimit == 0
              ? 'No emergency access'
              : '${d.emergencyLimit == 1 ? 'One unlock' : '${d.emergencyLimit} unlocks'} of ${formatMinutes(d.emergencyMinutes)}',
          lines: d.emergencyLimit == 0
              ? const ['The apps stay blocked until the challenge ends.']
              : const [
                  'It does not end your challenge.',
                  'The apps lock again by themselves.',
                ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------- Step 4: amount

class SelectAmountScreen extends StatefulWidget {
  const SelectAmountScreen({super.key, required this.draft});
  final CommitmentDraft draft;

  @override
  State<SelectAmountScreen> createState() => _SelectAmountScreenState();
}

class _SelectAmountScreenState extends State<SelectAmountScreen> {
  Future<void> _custom() async {
    final amount = await showDialog<int>(
      context: context,
      builder: (_) => const _CustomAmountDialog(),
    );
    if (amount != null) setState(() => widget.draft.amount = amount);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final a = d.amount;
    final isCustom = a != null && !CommitmentEngine.amounts.contains(a);
    final connected = CommitScope.of(context).payments.isConfigured;
    return StepPage(
      step: 4,
      question: 'How serious do you want your commitment to be?',
      why: 'Choose a Commitment Amount from ₹100 to ₹10,000. You pay it only if you end early.',
      actions: [
        PrimaryButton(
          'Continue',
          onPressed: a == null
              ? null
              : () => push(context, ReviewScreen(draft: d)),
        ),
      ],
      children: [
        ChipGroup<int>(
          title: 'Commitment Amount',
          values: CommitmentEngine.amounts,
          label: formatAmount,
          selected: a,
          onSelected: (v) => setState(() => d.amount = v),
        ),
        const SizedBox(height: AppSpace.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: OptionChip(
            label: isCustom ? 'Custom: ${formatAmount(a)}' : 'Custom amount',
            selected: isCustom,
            onTap: _custom,
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        OutcomeCard(amount: a == null ? null : formatAmount(a)),
        if (!connected) ...[
          const SizedBox(height: AppSpace.md),
          const Note(paymentsOffNote),
        ],
      ],
    );
  }
}

/// The promise of the app in three lines: what costs money and what does not.
class OutcomeCard extends StatelessWidget {
  const OutcomeCard({super.key, required this.amount, this.full = false});

  /// Formatted amount, or null before one is chosen.
  final String? amount;

  /// Also list the things that never cost anything.
  final bool full;

  @override
  Widget build(BuildContext context) => SummaryCard(
    children: [
      const OutcomeRow(
        icon: Icons.check,
        when: 'Complete the challenge',
        result: '₹0 charged',
        tone: Tone.success,
      ),
      OutcomeRow(
        icon: Icons.flag_outlined,
        when: 'End early',
        result: amount == null
            ? 'Your selected Commitment Amount becomes payable'
            : '$amount becomes payable',
        tone: Tone.warm,
      ),
      const OutcomeRow(
        icon: Icons.health_and_safety_outlined,
        when: 'Emergency access',
        result: 'Free',
      ),
      if (full)
        const OutcomeRow(
          icon: Icons.shield_outlined,
          when: 'Phone restarts, app closes, no internet',
          result: 'Never charged',
        ),
    ],
  );
}

/// Returns a whole rupee amount in the allowed range, or null if cancelled.
class _CustomAmountDialog extends StatefulWidget {
  const _CustomAmountDialog();

  @override
  State<_CustomAmountDialog> createState() => _CustomAmountDialogState();
}

class _CustomAmountDialogState extends State<_CustomAmountDialog> {
  String _text = '';

  int? get _amount {
    final n = int.tryParse(_text.trim());
    if (n == null ||
        n < CommitmentEngine.minAmount ||
        n > CommitmentEngine.maxAmount) {
      return null;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final amount = _amount;
    return AlertDialog(
      title: const Text('Custom amount'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            autofocus: true,
            keyboardType: TextInputType.number,
            style: AppText.subheading,
            decoration: const InputDecoration(prefixText: '₹ '),
            onChanged: (v) => setState(() => _text = v),
          ),
          const SizedBox(height: AppSpace.md),
          Note(
            'Whole rupees, ${formatAmount(CommitmentEngine.minAmount)} to ${formatAmount(CommitmentEngine.maxAmount)}.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: amount == null
              ? null
              : () => Navigator.of(context).pop(amount),
          child: const Text('Set'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------- Step 5: review

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.draft});
  final CommitmentDraft draft;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  bool _busy = false;
  bool _agreed = false;

  Future<void> _start() async {
    if (_busy) return; // guards against double taps
    setState(() => _busy = true);
    final c = CommitScope.of(context);
    final nav = Navigator.of(context);
    final d = widget.draft;
    try {
      await c.refreshProtection();
      if (!c.readyToStart) return;
      await c.createCommitment(
        apps: [for (final a in d.apps) AppRef(a.packageName, a.appName)],
        durationMinutes: d.minutes!,
        amount: Features.payments ? d.amount! : 0,
        consentAccepted: _agreed,
        emergencyLimit: d.emergencyLimit,
        emergencyMinutes: d.emergencyMinutes,
      );
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
          'The challenge could not be saved. Nothing was started. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = CommitScope.of(context);
    final d = widget.draft;
    final enabled = c.readyToStart;
    final money = Features.payments;
    final amount = money ? formatAmount(d.amount!) : '';
    final ends = c.now.add(Duration(minutes: d.minutes!));
    return StepPage(
      step: money ? 5 : 4,
      question: 'Review & start',
      why: 'Check everything. Once it starts, it cannot be changed.',
      actions: [
        if (!enabled)
          SecondaryButton(
            'Finish blocking setup',
            onPressed: () => push(context, const PermissionScreen()),
          ),
        PrimaryButton(
          _busy
              ? 'Starting…'
              : !_agreed
              ? 'Tick the box to start'
              : 'Start challenge',
          onPressed: (_busy || !enabled || !_agreed) ? null : _start,
        ),
        QuietButton(
          'Cancel',
          onPressed: _busy
              ? null
              : () => Navigator.of(context).popUntil((r) => r.isFirst),
        ),
      ],
      children: [
        const SectionLabel('Your challenge'),
        const SizedBox(height: AppSpace.sm),
        SummaryCard(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: AppSpace.lg,
                  runSpacing: AppSpace.sm,
                  children: [
                    for (final a in d.apps)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppIcon(
                            packageName: a.packageName,
                            appName: a.appName,
                            bytes: a.icon,
                            size: 28,
                          ),
                          const SizedBox(width: AppSpace.sm),
                          Text(a.appName, style: AppText.title),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            InfoRow('Duration', formatMinutes(d.minutes!)),
            InfoRow('Ends', formatWhen(ends)),
            InfoRow(
              'Emergency access',
              formatEmergencySummary(d.emergencyLimit, d.emergencyMinutes),
            ),
            if (money) InfoRow('Commitment Amount', amount),
          ],
        ),
        const SizedBox(height: AppSpace.xl),
        const SectionLabel('What happens'),
        const SizedBox(height: AppSpace.sm),
        if (money) ...[
          OutcomeCard(amount: amount, full: true),
          if (!c.payments.isConfigured) ...[
            const SizedBox(height: AppSpace.md),
            const Note(paymentsOffNote),
          ],
        ] else
          const SummaryCard(
            children: [
              OutcomeRow(
                icon: Icons.lock_outline,
                when: 'Until the end time',
                result: 'These apps stay blocked',
              ),
              OutcomeRow(
                icon: Icons.health_and_safety_outlined,
                when: 'Emergency access',
                result: 'Only what you allowed above',
              ),
              OutcomeRow(
                icon: Icons.check,
                when: 'At the end',
                result: 'Your apps unlock by themselves',
                tone: Tone.success,
              ),
            ],
          ),
        const SizedBox(height: AppSpace.lg),
        Material(
          color: _agreed ? AppColors.brandSoft : AppColors.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
            side: BorderSide(
              color: _agreed ? AppColors.brand : AppColors.line,
              width: _agreed ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: CheckboxListTile(
            value: _agreed,
            activeColor: AppColors.brand,
            onChanged: _busy
                ? null
                : (v) => setState(() => _agreed = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              money
                  ? CommitmentEngine.consentText(amount)
                  : CommitmentEngine.plainConsentText,
              style: AppText.body.copyWith(fontSize: 15),
            ),
          ),
        ),
        if (!enabled) ...[
          const SizedBox(height: AppSpace.lg),
          const NoticeCard(
            icon: Icons.shield_outlined,
            title: 'Finish the blocking setup to start.',
          ),
        ],
      ],
    );
  }
}
