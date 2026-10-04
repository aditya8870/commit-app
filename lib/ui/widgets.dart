import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/commitment.dart';
import '../core/features.dart';
import '../data/commit_controller.dart';
import 'format.dart';
import 'screens/create_flow.dart';
import 'theme.dart';

export 'theme.dart';

/// Gives screens access to the controller and rebuilds them when it changes.
class CommitScope extends InheritedNotifier<CommitController> {
  const CommitScope({
    super.key,
    required CommitController controller,
    required super.child,
  }) : super(notifier: controller);

  static CommitController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CommitScope>()!.notifier!;
}

void push(BuildContext context, Widget screen) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

// ------------------------------------------------------------------ layout

/// Standard page: optional app bar, scrollable body, actions pinned at the
/// bottom.
class AppPage extends StatelessWidget {
  const AppPage({
    super.key,
    this.title,
    required this.children,
    this.actions = const [],
    this.appBarActions,
    this.centered = false,
  });

  final String? title;
  final List<Widget> children;
  final List<Widget> actions;
  final List<Widget>? appBarActions;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: title == null
          ? null
          : AppBar(title: Text(title!), actions: appBarActions),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.xl,
                    AppSpace.lg,
                    AppSpace.xl,
                    AppSpace.lg,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: box.maxHeight - 2 * AppSpace.lg,
                    ),
                    child: Column(
                      mainAxisAlignment: centered
                          ? MainAxisAlignment.center
                          : MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ),
              ),
            ),
            if (actions.isNotEmpty) ActionBar(children: actions),
          ],
        ),
      ),
    );
  }
}

/// The bottom action area: stacked, full-width, consistent spacing.
class ActionBar extends StatelessWidget {
  const ActionBar({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.xl,
      AppSpace.sm,
      AppSpace.xl,
      AppSpace.lg,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(height: AppSpace.sm),
          children[i],
        ],
      ],
    ),
  );
}

/// "Step 2 of 4" with a segment bar.
class StepHeader extends StatelessWidget {
  const StepHeader({
    super.key,
    required this.step,
    required this.question,
    this.why,
  });

  static int get total => Features.payments ? 5 : 4;
  final int step;
  final String question;

  /// One line on why this decision matters.
  final String? why;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          for (var i = 1; i <= total; i++) ...[
            if (i > 1) const SizedBox(width: 6),
            Expanded(
              child: Container(
                height: 5,
                decoration: BoxDecoration(
                  color: i <= step ? AppColors.brand : AppColors.line,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: AppSpace.md),
      Text('Step $step of $total', style: AppText.label),
      const SizedBox(height: AppSpace.sm),
      Text(question, style: AppText.heading),
      if (why != null) ...[
        const SizedBox(height: AppSpace.sm),
        Text(why!, style: AppText.bodyMuted),
      ],
    ],
  );
}

/// Page used by the creation steps.
class StepPage extends StatelessWidget {
  const StepPage({
    super.key,
    required this.step,
    required this.question,
    required this.children,
    required this.actions,
    this.why,
  });

  static int get total => StepHeader.total;
  final int step;
  final String question;
  final String? why;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => AppPage(
    title: 'New challenge',
    actions: actions,
    children: [
      StepHeader(step: step, question: question, why: why),
      const SizedBox(height: AppSpace.xl),
      ...children,
    ],
  );
}

// ----------------------------------------------------------------- buttons

ButtonStyle _buttonShape() => ButtonStyle(
  minimumSize: const WidgetStatePropertyAll(Size.fromHeight(56)),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.button),
    ),
  ),
  textStyle: const WidgetStatePropertyAll(AppText.button),
);

/// The safe, expected action on a screen. One per screen.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.label, {super.key, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: onPressed,
    style: _buttonShape().merge(
      FilledButton.styleFrom(
        backgroundColor: AppColors.brand,
        foregroundColor: Colors.white,
        disabledBackgroundColor: AppColors.disabledFill,
        disabledForegroundColor: AppColors.faint,
      ),
    ),
    child: Text(label, textAlign: TextAlign.center),
  );
}

/// A real alternative to the primary action.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton(this.label, {super.key, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: _buttonShape().merge(
      OutlinedButton.styleFrom(
        foregroundColor: AppColors.brand,
        disabledForegroundColor: AppColors.faint,
        side: BorderSide(
          color: onPressed == null ? AppColors.line : AppColors.brand,
          width: 1.5,
        ),
      ),
    ),
    child: Text(label, textAlign: TextAlign.center),
  );
}

/// Low-emphasis text action, for things that should not be tapped casually
/// (ending a challenge early) or that simply dismiss.
class QuietButton extends StatelessWidget {
  const QuietButton(this.label, {super.key, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      minimumSize: const Size.fromHeight(48),
      foregroundColor: AppColors.muted,
      textStyle: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
    ),
    child: Text(label, textAlign: TextAlign.center),
  );
}

// ------------------------------------------------------------------- chips

/// Pill-shaped option used for durations, emergency settings and amounts.
class OptionChip extends StatelessWidget {
  const OptionChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      color: selected ? AppColors.brand : AppColors.card,
      shape: StadiumBorder(
        side: BorderSide(color: selected ? AppColors.brand : AppColors.line),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 72),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : AppColors.ink,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A titled group of [OptionChip]s that wraps onto as many lines as needed.
class ChipGroup<T> extends StatelessWidget {
  const ChipGroup({
    super.key,
    required this.title,
    required this.values,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String title;
  final List<T> values;
  final String Function(T) label;
  final T? selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SectionLabel(title),
      const SizedBox(height: AppSpace.md),
      Wrap(
        spacing: AppSpace.sm,
        runSpacing: AppSpace.sm,
        children: [
          for (final v in values)
            OptionChip(
              label: label(v),
              selected: v == selected,
              onTap: () => onSelected(v),
            ),
        ],
      ),
    ],
  );
}

/// Small uppercase heading above a group.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: AppText.label);
}

/// Coloured pill showing a status.
class StatusPill extends StatelessWidget {
  const StatusPill(this.label, {super.key, this.tone = Tone.brand});
  final String label;
  final Tone tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: 6),
    decoration: BoxDecoration(
      color: tone.soft,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: tone.strong,
      ),
    ),
  );
}

/// The three moods the UI uses. There is deliberately no "danger".
enum Tone {
  brand(AppColors.brand, AppColors.brandSoft),
  warm(AppColors.warm, AppColors.warmSoft),
  success(AppColors.success, AppColors.successSoft),
  neutral(AppColors.muted, Color(0xFFEDEBE5));

  const Tone(this.strong, this.soft);
  final Color strong;
  final Color soft;
}

// ------------------------------------------------------------------- cards

/// "Label ........ value" row inside summary cards.
class InfoRow extends StatelessWidget {
  const InfoRow(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 4, child: Text(label, style: AppText.small)),
        const SizedBox(width: AppSpace.md),
        Expanded(
          flex: 6,
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: AppText.title.copyWith(fontSize: 16),
          ),
        ),
      ],
    ),
  );
}

/// A card of rows separated by hairlines.
class SummaryCard extends StatelessWidget {
  const SummaryCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg + 2,
        vertical: AppSpace.xs,
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            children[i],
          ],
        ],
      ),
    ),
  );
}

/// One number with a caption, e.g. "₹100 / Commitment Amount".
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
  });
  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: AppColors.brand),
              const SizedBox(height: AppSpace.sm),
            ],
            Text(value, style: AppText.subheading),
            const SizedBox(height: 2),
            Text(label, style: AppText.small),
          ],
        ),
      ),
    ),
  );
}

/// Small grey supporting text.
class Note extends StatelessWidget {
  const Note(this.text, {super.key, this.center = false});
  final String text;
  final bool center;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: center ? TextAlign.center : TextAlign.start,
    style: AppText.small,
  );
}

/// A calm message card: title, optional body, optional action.
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    super.key,
    required this.title,
    this.lines = const [],
    this.tone = Tone.warm,
    this.icon,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
  });

  final String title;
  final List<String> lines;
  final Tone tone;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: tone.soft,
      borderRadius: BorderRadius.circular(AppRadius.card),
    ),
    padding: const EdgeInsets.all(AppSpace.lg),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 22, color: tone.strong),
              const SizedBox(width: AppSpace.md),
            ],
            Expanded(child: Text(title, style: AppText.title)),
            if (onDismiss != null)
              InkWell(
                onTap: onDismiss,
                customBorder: const CircleBorder(),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 20, color: AppColors.muted),
                ),
              ),
          ],
        ),
        for (final line in lines) ...[
          const SizedBox(height: AppSpace.xs),
          Text(line, style: AppText.body.copyWith(fontSize: 15)),
        ],
        if (actionLabel != null) ...[
          const SizedBox(height: AppSpace.md),
          SecondaryButton(actionLabel!, onPressed: onAction),
        ],
      ],
    ),
  );
}

/// One line of "if this happens → that is the result".
class OutcomeRow extends StatelessWidget {
  const OutcomeRow({
    super.key,
    required this.icon,
    required this.when,
    required this.result,
    this.tone = Tone.brand,
  });
  final IconData icon;
  final String when;
  final String result;
  final Tone tone;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(color: tone.soft, shape: BoxShape.circle),
          child: Icon(icon, size: 20, color: tone.strong),
        ),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(when, style: AppText.small),
              const SizedBox(height: 2),
              Text(result, style: AppText.title),
            ],
          ),
        ),
      ],
    ),
  );
}

// ------------------------------------------------------------ app-specific

/// Shown wherever money is mentioned while no payment provider is connected.
const paymentsOffNote =
    'Test version: payments are not connected, so nothing can be charged yet.';

/// App icon from the phone, or a letter if the icon is not loaded.
class AppIcon extends StatelessWidget {
  const AppIcon({
    super.key,
    required this.packageName,
    required this.appName,
    this.bytes,
    this.size = 40,
  });

  final String packageName;
  final String appName;
  final Uint8List? bytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = bytes ?? CommitScope.of(context).icons[packageName];
    if (icon != null) {
      return Image.memory(
        icon,
        width: size,
        height: size,
        gaplessPlayback: true,
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.brandSoft,
        borderRadius: BorderRadius.circular(size / 4),
      ),
      child: Text(
        appName.isEmpty ? '?' : appName[0].toUpperCase(),
        style: TextStyle(
          fontSize: size * 0.45,
          fontWeight: FontWeight.w700,
          color: AppColors.brand,
        ),
      ),
    );
  }
}

/// The protected apps as a wrap of icon + name pills.
class AppPills extends StatelessWidget {
  const AppPills(this.apps, {super.key, this.onTap});
  final List<AppRef> apps;

  /// When set, pills are tappable (used during emergency access).
  final void Function(AppRef app)? onTap;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: AppSpace.sm,
    runSpacing: AppSpace.sm,
    children: [
      for (final a in apps)
        Material(
          color: AppColors.card,
          shape: const StadiumBorder(side: BorderSide(color: AppColors.line)),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap == null ? null : () => onTap!(a),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(
                    packageName: a.packageName,
                    appName: a.appName,
                    size: 28,
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Flexible(
                    child: Text(
                      a.appName,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.title.copyWith(fontSize: 15),
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.open_in_new,
                      size: 16,
                      color: AppColors.brand,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

/// The countdown inside a ring that fills as the challenge progresses.
class TimeRing extends StatelessWidget {
  const TimeRing({
    super.key,
    required this.progress,
    required this.time,
    required this.caption,
    this.tone = Tone.brand,
    this.size = 232,
  });

  /// 0..1: how much of the challenge (or emergency access) is done.
  final double progress;
  final String time;
  final String caption;
  final Tone tone;
  final double size;

  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CircularProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              strokeWidth: 12,
              strokeCap: StrokeCap.round,
              color: tone.strong,
              backgroundColor: tone.soft,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    time,
                    style: AppText.timer.copyWith(fontSize: size * 0.2),
                  ),
                ),
                const SizedBox(height: 4),
                Text(caption, style: AppText.small),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Shown wherever a challenge is running but blocking is weakened.
class ProtectionBanner extends StatelessWidget {
  const ProtectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final c = CommitScope.of(context);
    final a = c.active;
    if (a == null) return const SizedBox.shrink();

    void open() => push(context, const PermissionScreen());

    // Nothing can block the apps right now.
    if (!c.protectionEnabled) {
      return Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.lg),
        child: NoticeCard(
          icon: Icons.shield_outlined,
          title: 'Your protection has been interrupted.',
          lines: [
            'Your challenge is still active.',
            if (Features.payments && a.commitmentAmount > 0)
              'Commitment Amount: ${formatAmount(a.commitmentAmount)}',
            'Please restore protection to continue your commitment.',
          ],
          actionLabel: 'Restore protection',
          onAction: open,
        ),
      );
    }

    // Still blocking, but something that was on has been switched off.
    final String? notice = !c.fullProtection ? protectionSummary(c) : null;
    if (notice == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: const Icon(Icons.shield_outlined, color: AppColors.warm),
          title: Text(notice, style: AppText.title.copyWith(fontSize: 16)),
          subtitle: const Text('Tap to restore it.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: open,
        ),
      ),
    );
  }
}

/// Plain-language summary of how well blocking is set up.
String protectionSummary(CommitController c) {
  if (c.fullProtection) return 'Blocking is fully on';
  if (c.accessibilityEnabled) return 'Blocking is on (backup is off)';
  if (c.backupEnabled) return 'Blocking is on in backup mode';
  return 'Blocking is off';
}
