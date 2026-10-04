import 'commitment.dart';
import 'payment.dart';

/// Why an operation was refused. The UI turns these into messages.
enum CommitmentError {
  duplicateActive('You already have an active commitment.'),
  invalidAmount('Choose a Commitment Amount between ₹100 and ₹10,000.'),
  noAmount(
    'This challenge has no Commitment Amount, so it cannot be ended early.',
  ),
  endingSoon('Your challenge ends in under a minute. Keep going.'),
  endEarlyUnavailable(
    'A challenge cannot be ended early. It ends by itself at the end time.',
  ),
  paymentInProgress('A payment is already in progress.'),
  consentRequired(
    'Please confirm that you understand the Commitment Amount before starting.',
  ),
  registrationUnresolved(
    'An earlier challenge is still being confirmed with the server. Please try again when you are online.',
  ),
  serverUnavailable(
    'The server could not be reached. Nothing was started. Please try again.',
  ),
  invalidServerTerms(
    'The server returned an invalid challenge. Nothing was started.',
  ),
  invalidDuration('Please choose a duration between 1 minute and 30 days.'),
  invalidApp('One of the selected apps cannot be blocked.'),
  noApps('Select at least one app.'),
  noEmergencyLeft('No emergency access remaining for this commitment.'),
  invalidEmergencyLimit('Emergency access can be 0 to 3 uses.'),
  noActiveCommitment('There is no active commitment.'),
  emergencyAlreadyActive('Emergency access is already active.'),
  invalidEmergencyDuration('Please choose one of the emergency durations.');

  const CommitmentError(this.message);
  final String message;
}

class CommitmentException implements Exception {
  const CommitmentException(this.error);
  final CommitmentError error;
  @override
  String toString() => error.message;
}

class CommitmentStats {
  const CommitmentStats({
    required this.total,
    required this.completed,
    required this.emergencyUses,
    this.endedEarly = 0,
    this.interrupted = 0,
  });
  final int total;
  final int completed;
  final int emergencyUses;
  final int endedEarly;

  /// Reached the end time, but protection was interrupted on the way.
  final int interrupted;

  /// Whole percent, completed / total.
  int get completionRate => total == 0 ? 0 : (completed * 100 / total).round();
}

/// The state shown to the user. [CommitmentStatus] is what is stored and what
/// the blocking service acts on; this adds the conditions that sit on top of
/// a running challenge. A challenge in any of the first four states is still
/// running and still blocks its apps wherever a detector can work.
enum ChallengeState {
  active('ACTIVE', 'Active'),
  emergency('EMERGENCY', 'Emergency access'),
  protectionInterrupted('PROTECTION_INTERRUPTED', 'Protection interrupted'),
  paymentPending('PAYMENT_PENDING', 'Payment pending'),
  paymentVerified('PAYMENT_VERIFIED', 'Payment verified'),
  endedEarly('ENDED_EARLY', 'Ended early'),
  completed('COMPLETED', 'Completed'),
  cancelled('CANCELLED', 'Cancelled');

  const ChallengeState(this.wire, this.label);
  final String wire;
  final String label;
}

/// Pure, deterministic rules. No timers, no I/O: everything is a function of
/// the stored timestamps and the current time passed in.
class CommitmentEngine {
  const CommitmentEngine._();

  /// Quick-pick durations, grouped the way the selector shows them.
  static const List<int> shortDurations = [2, 5, 10, 15, 30];
  static const List<int> hourDurations = [60, 120, 180, 360, 720];
  static const List<int> dayDurations = [1440, 2880, 4320, 10080, 20160, 43200];

  /// Any whole number of minutes in this range is allowed (custom duration).
  static const int minDurationMinutes = 1;
  static const int maxDurationMinutes = 43200; // 30 days

  /// Suggested Commitment Amounts in rupees. The user may also enter any
  /// whole number in the allowed range.
  static const List<int> amounts = [100, 500, 1000, 2500, 5000, 10000];
  static const int minAmount = 100;
  static const int maxAmount = 10000;

  /// Identifies the wording of [consentText]. Change it whenever the wording
  /// changes, so a stored consent always points at the text that was shown.
  static const String consentVersion = '2026-10-06.1';

  /// The sentence ticked before starting when no money is involved.
  static const String plainConsentText =
      'I understand that these apps stay blocked until the challenge ends '
      'and that the challenge cannot be shortened once it starts.';

  /// The sentence the user ticks before starting. [amount] is already
  /// formatted, e.g. "₹100".
  static String consentText(String amount) =>
      'By starting this challenge, I understand that ending the challenge '
      'early will require payment of $amount.';

  /// Ending early is not offered in the final moments, so a payment cannot
  /// be started for a challenge that is about to complete by itself.
  static const Duration endEarlyCutoff = Duration(seconds: 60);

  static const List<int> emergencyLimits = [0, 1, 2, 3];
  static const List<int> emergencyDurationsMinutes = [2, 5, 10, 15, 30];
  static const int defaultEmergencyMinutes = 5;

  static Commitment create({
    required String id,
    required List<AppRef> apps,
    required int durationMinutes,
    required DateTime now,
    required int amount,
    int emergencyLimit = 0,
    int emergencyMinutes = defaultEmergencyMinutes,
    DateTime? endTime,
    String? ownerUserId,
    bool serverIssued = false,
    String? registrationKey,
    ConsentRecord? consent,
  }) {
    if (apps.isEmpty) throw const CommitmentException(CommitmentError.noApps);
    final seen = <String>{};
    for (final a in apps) {
      if (a.packageName.isEmpty ||
          a.appName.isEmpty ||
          !seen.add(a.packageName)) {
        throw const CommitmentException(CommitmentError.invalidApp);
      }
    }
    if (durationMinutes < minDurationMinutes ||
        durationMinutes > maxDurationMinutes) {
      throw const CommitmentException(CommitmentError.invalidDuration);
    }
    // 0 means "no financial commitment" (the only kind in this release).
    if (amount != 0 && (amount < minAmount || amount > maxAmount)) {
      throw const CommitmentException(CommitmentError.invalidAmount);
    }
    if (!emergencyLimits.contains(emergencyLimit)) {
      throw const CommitmentException(CommitmentError.invalidEmergencyLimit);
    }
    if (!emergencyDurationsMinutes.contains(emergencyMinutes)) {
      throw const CommitmentException(CommitmentError.invalidEmergencyDuration);
    }
    return Commitment(
      id: id,
      apps: List.unmodifiable(apps),
      startTime: now,
      endTime: endTime ?? now.add(Duration(minutes: durationMinutes)),
      durationMinutes: durationMinutes,
      commitmentAmount: amount,
      ownerUserId: ownerUserId,
      serverIssued: serverIssued,
      registrationKey: registrationKey,
      consent: consent,
      status: CommitmentStatus.active,
      createdAt: now,
      emergencyLimit: emergencyLimit,
      emergencyMinutes: emergencyMinutes,
    );
  }

  /// Whether "End Challenge" may be offered right now.
  static bool canEndEarly(Commitment c, DateTime now) =>
      resolve(c, now).isLive &&
      c.commitmentAmount > 0 &&
      remaining(c, now) > endEarlyCutoff;

  /// Ends the challenge early. Only ever called with a payment that the
  /// payment service has VERIFIED as successful.
  static Commitment endEarly(
    Commitment c,
    PaymentRecord verified,
    DateTime now,
  ) {
    assert(verified.status == PaymentStatus.successful);
    var at = verified.paidAt ?? now;
    if (at.isBefore(c.startTime)) at = c.startTime;
    return c.copyWith(
      status: CommitmentStatus.endedEarly,
      payment: verified,
      actualEndTime: at,
      completedAt: at,
    );
  }

  /// The explicit state of a challenge.
  ///
  /// [protectionOk] is whether a detector can currently block the apps; it is
  /// only meaningful for a running challenge.
  static ChallengeState stateOf(
    Commitment c,
    DateTime now, {
    bool protectionOk = true,
  }) {
    final r = resolve(c, now);
    final paid = r.payment?.status == PaymentStatus.successful;
    switch (r.status) {
      case CommitmentStatus.endedEarly:
        return ChallengeState.endedEarly;
      case CommitmentStatus.cancelled:
        return ChallengeState.cancelled;
      case CommitmentStatus.completed:
        // A payment that was verified only after the challenge had already
        // finished by itself: on record, to be settled, never charged again.
        return paid ? ChallengeState.paymentVerified : ChallengeState.completed;
      case CommitmentStatus.active:
      case CommitmentStatus.emergency:
        if (r.payment?.status.mustVerifyBeforeRetry == true) {
          return ChallengeState.paymentPending;
        }
        if (!protectionOk) return ChallengeState.protectionInterrupted;
        return r.status == CommitmentStatus.emergency
            ? ChallengeState.emergency
            : ChallengeState.active;
    }
  }

  /// Total time the apps were unprotected, up to [now] or the challenge end.
  static Duration interruptedTime(Commitment c, DateTime now) {
    var limit = c.actualEndTime ?? c.endTime;
    if (now.isBefore(limit)) limit = now;
    var total = Duration.zero;
    DateTime? open;
    for (final e in c.integrityEvents) {
      var at = e.at;
      if (at.isBefore(c.startTime)) at = c.startTime;
      if (at.isAfter(limit)) at = limit;
      if (e.opensGap) {
        open ??= at;
      } else if (e.closesGap && open != null) {
        total += at.difference(open);
        open = null;
      }
    }
    if (open != null && limit.isAfter(open)) total += limit.difference(open);
    return total;
  }

  /// A challenge counts as fully kept only if protection was never interrupted.
  static bool keptCleanly(Commitment c) =>
      c.status == CommitmentStatus.completed &&
      c.interruptionCount == 0 &&
      !c.restored;

  static bool inEmergencyWindow(Commitment c, DateTime now) {
    final s = c.lastEmergencyStart, e = c.lastEmergencyEnd;
    return s != null && e != null && !now.isBefore(s) && now.isBefore(e);
  }

  /// The commitment as it should be at [now]:
  /// past endTime -> COMPLETED; inside the emergency window -> EMERGENCY;
  /// otherwise ACTIVE. Finished commitments never change.
  static Commitment resolve(Commitment c, DateTime now) {
    if (!c.isLive) return c;
    if (!now.isBefore(c.endTime)) {
      return c.copyWith(
        status: CommitmentStatus.completed,
        completedAt: c.endTime,
      );
    }
    final target = inEmergencyWindow(c, now)
        ? CommitmentStatus.emergency
        : CommitmentStatus.active;
    return c.status == target ? c : c.copyWith(status: target);
  }

  /// True when the selected app must be blocked right now.
  static bool isBlocking(Commitment c, DateTime now) =>
      resolve(c, now).status == CommitmentStatus.active;

  static Duration remaining(Commitment c, DateTime now) {
    final d = c.endTime.difference(now);
    return d.isNegative ? Duration.zero : d;
  }

  static Duration emergencyRemaining(Commitment c, DateTime now) {
    if (!inEmergencyWindow(c, now)) return Duration.zero;
    return c.lastEmergencyEnd!.difference(now);
  }

  /// Starts one temporary access of the length chosen when the commitment
  /// was made. Refused while one is running or when none are left. The
  /// original endTime is never changed; the emergency window is clipped so it
  /// cannot outlast the commitment.
  static Commitment startEmergency(Commitment c, DateTime now) {
    final current = resolve(c, now);
    if (current.status == CommitmentStatus.emergency) {
      throw const CommitmentException(CommitmentError.emergencyAlreadyActive);
    }
    if (current.status != CommitmentStatus.active) {
      throw const CommitmentException(CommitmentError.noActiveCommitment);
    }
    if (c.emergencyRemaining <= 0) {
      throw const CommitmentException(CommitmentError.noEmergencyLeft);
    }
    var end = now.add(Duration(minutes: c.emergencyMinutes));
    if (end.isAfter(c.endTime)) end = c.endTime;
    return current.copyWith(
      status: CommitmentStatus.emergency,
      lastEmergencyStart: now,
      lastEmergencyEnd: end,
      emergencyAccessCount: c.emergencyAccessCount + 1,
    );
  }

  static CommitmentStats stats(Iterable<Commitment> all) {
    var total = 0, completed = 0, uses = 0, early = 0, interrupted = 0;
    for (final c in all) {
      total++;
      if (c.status == CommitmentStatus.completed) {
        if (keptCleanly(c)) {
          completed++;
        } else {
          interrupted++;
        }
      }
      if (c.status == CommitmentStatus.endedEarly) early++;
      uses += c.emergencyAccessCount;
    }
    return CommitmentStats(
      total: total,
      completed: completed,
      emergencyUses: uses,
      endedEarly: early,
      interrupted: interrupted,
    );
  }

  static const List<String> motivationalMessages = [
    'You made the decision before temptation — and you kept it.',
    'Small commitments become stronger self-control.',
    'You proved that you can follow through.',
    'You chose your long-term goal over a short-term impulse.',
    'Another promise to yourself, kept.',
    'Your future self will thank you.',
  ];

  /// Stable per commitment, so the same message shows if the screen reopens.
  static String messageFor(Commitment c) {
    final seed = c.id.codeUnits.fold<int>(0, (a, b) => a + b);
    return motivationalMessages[seed % motivationalMessages.length];
  }
}
