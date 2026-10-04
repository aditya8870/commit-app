import '../core/commitment.dart';
import '../core/payment.dart';

String _plural(int n, String unit) => n == 1 ? '1 $unit' : '$n ${unit}s';

/// "5d 14h", "18h 42m", "42m 05s", "9s".
String formatRemaining(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final days = d.inDays, h = d.inHours % 24;
  final m = d.inMinutes % 60, s = d.inSeconds % 60;
  if (days > 0) return '${days}d ${h}h';
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s.toString().padLeft(2, '0')}s';
  return '${s}s';
}

/// Countdown clock: "04:32", or "1:04:32" from one hour up.
String formatClock(Duration d) {
  if (d.isNegative) d = Duration.zero;
  String two(int v) => v.toString().padLeft(2, '0');
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// "₹1,000".
String formatAmount(int rupees) {
  final digits = rupees.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return '₹$out';
}

/// "2 minutes", "1 hour", "7 days", "1 day 6 hours".
String formatMinutes(int minutes) {
  final d = minutes ~/ 1440, h = (minutes % 1440) ~/ 60, m = minutes % 60;
  final parts = [
    if (d > 0) _plural(d, 'day'),
    if (h > 0) _plural(h, 'hour'),
    if (m > 0) _plural(m, 'minute'),
  ];
  return parts.isEmpty ? '0 minutes' : parts.join(' ');
}

/// Compact label for a duration chip: "2 min", "1 hr", "7 days".
String formatChip(int minutes) {
  if (minutes % 1440 == 0) return _plural(minutes ~/ 1440, 'day');
  if (minutes % 60 == 0) return '${minutes ~/ 60} hr';
  return '$minutes min';
}

/// "7-day", "2-hour", "30-minute"; falls back to "1 day 6 hours".
String formatMinutesAdjective(int minutes) {
  if (minutes % 1440 == 0) return '${minutes ~/ 1440}-day';
  if (minutes % 60 == 0) return '${minutes ~/ 60}-hour';
  if (minutes < 60) return '$minutes-minute';
  return formatMinutes(minutes);
}

/// "7-Day Digital Detox".
String commitmentTitle(int minutes) {
  if (minutes % 1440 == 0) return '${minutes ~/ 1440}-Day Digital Detox';
  if (minutes % 60 == 0) return '${minutes ~/ 60}-Hour Digital Detox';
  if (minutes < 60) return '$minutes-Minute Digital Detox';
  return 'Digital Detox';
}

/// "Instagram + YouTube + Facebook", "Instagram + YouTube + 2 more".
String appsLabel(List<String> names, {int max = 3}) {
  if (names.length <= max) return names.join(' + ');
  return '${names.take(max - 1).join(' + ')} + ${names.length - max + 1} more';
}

String formatEmergencyUses(int n) => _plural(n, 'emergency use');

/// "No emergency access", "1 use", "2 uses".
String formatEmergencyLimit(int n) =>
    n == 0 ? 'No emergency access' : _plural(n, 'use');

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "3 Oct 2026, 14:05".
String formatDateTime(DateTime t) =>
    '${t.day} ${_months[t.month - 1]} ${t.year}, '
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String statusLabel(CommitmentStatus s) => switch (s) {
  CommitmentStatus.active => 'Active',
  CommitmentStatus.emergency => 'Emergency access',
  CommitmentStatus.completed => 'Completed',
  CommitmentStatus.endedEarly => 'Ended early',
  CommitmentStatus.cancelled => 'Cancelled',
};

/// "1 × 5 minutes", "None".
String formatEmergencySummary(int limit, int minutes) =>
    limit == 0 ? 'None' : '$limit × ${formatMinutes(minutes)}';

/// "24 hours", "7 days": the length of a challenge in words.
String formatLength(int minutes) => formatMinutes(minutes);

/// "Sat 4 Oct, 21:30".
String formatWhen(DateTime t) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String two(int v) => v.toString().padLeft(2, '0');
  return '${days[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}, '
      '${two(t.hour)}:${two(t.minute)}';
}

/// "1 of 2 left", "None".
String emergencyLeft(Commitment c) => c.emergencyLimit == 0
    ? 'None'
    : '${c.emergencyRemaining} of ${c.emergencyLimit} left';

/// How a challenge turned out, for History.
String resultLabel(Commitment c) => switch (c.status) {
  CommitmentStatus.active || CommitmentStatus.emergency => 'In progress',
  CommitmentStatus.completed =>
    c.interruptionCount > 0
        ? 'Ended · protection interrupted'
        : c.restored
        ? 'Ended · restored'
        : '✓ Completed',
  CommitmentStatus.endedEarly => 'Ended early',
  CommitmentStatus.cancelled => 'Cancelled',
};

/// What happened with the Commitment Amount, for History. States only what
/// is on record.
String paymentLine(Commitment c) {
  final amount = formatAmount(c.commitmentAmount);
  final p = c.payment;
  if (p != null && p.refund == RefundStatus.refunded) return '$amount refunded';
  if (p != null && p.refund == RefundStatus.pending) {
    return 'Refund in progress';
  }
  if (p != null && p.status == PaymentStatus.successful) return '$amount paid';
  if (p != null && p.status.mustVerifyBeforeRetry) return 'Payment pending';
  return switch (c.status) {
    CommitmentStatus.completed => '₹0 payable',
    CommitmentStatus.cancelled => 'Nothing payable',
    _ => 'Nothing charged',
  };
}

/// Calm time left, without ticking seconds: "5d 14h", "2h 45m", "12 min",
/// "Under 1 min". Minutes are rounded up so it never shows less than is left.
String formatTimeLeft(Duration d) {
  if (d.isNegative) d = Duration.zero;
  if (d.inSeconds < 60) return 'Under 1 min';
  final total = (d.inSeconds + 59) ~/ 60;
  final days = total ~/ 1440, h = (total % 1440) ~/ 60, m = total % 60;
  if (days > 0) return '${days}d ${h}h';
  if (h > 0) return '${h}h ${m}m';
  return '$m min';
}

/// Time left as a short sentence: "2 days 4 hours remaining",
/// "2h 34m remaining", "12 min remaining".
String formatRemainingSentence(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final total = (d.inSeconds + 59) ~/ 60;
  final days = total ~/ 1440, h = (total % 1440) ~/ 60;
  if (days > 0) {
    return '${_plural(days, 'day')}${h > 0 ? ' ${_plural(h, 'hour')}' : ''} remaining';
  }
  return '${formatTimeLeft(d)} remaining';
}
