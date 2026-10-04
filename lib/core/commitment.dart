import 'payment.dart';

/// Stored status of a commitment. The *effective* status is always re-derived
/// from timestamps by `CommitmentEngine.resolve`.
enum CommitmentStatus {
  active('ACTIVE'),
  emergency('EMERGENCY'),
  completed('COMPLETED'),

  /// The user ended the challenge before its end time, after a verified
  /// payment of the Commitment Amount.
  endedEarly('ENDED_EARLY'),
  cancelled('CANCELLED');

  const CommitmentStatus(this.wire);
  final String wire;

  static CommitmentStatus parse(Object? value) => values.firstWhere(
    (s) => s.wire == value,
    orElse: () => throw FormatException('Unknown status: $value'),
  );
}

/// Something that weakened protection during a challenge. Recorded for the
/// challenge; never a reason to charge or to end it.
class IntegrityEvent {
  const IntegrityEvent(this.type, this.at);

  static const forceStopped = 'forceStopped';
  static const accessibilityOff = 'accessibilityOff';
  static const protectionLost = 'protectionLost';
  static const protectionRestored = 'protectionRestored';
  static const tamperProtectionOff = 'tamperProtectionOff';

  /// The phone lost its copy of the challenge (data cleared or app
  /// reinstalled) and got it back from the server. What happened in between
  /// is unknown, so the challenge is not counted as cleanly kept.
  static const restoredOnDevice = 'restoredOnDevice';

  final String type;
  final DateTime at;

  /// Starts a period in which nothing was blocking the apps.
  bool get opensGap => type == forceStopped || type == protectionLost;
  bool get closesGap => type == protectionRestored;

  Map<String, Object?> toJson() => {
    'type': type,
    'at': at.millisecondsSinceEpoch,
  };

  static IntegrityEvent? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final type = raw['type'], at = raw['at'];
    if (type is! String || type.isEmpty || at is! int || at <= 0) return null;
    return IntegrityEvent(type, DateTime.fromMillisecondsSinceEpoch(at));
  }
}

/// Evidence that the user accepted the payment condition before starting.
class ConsentRecord {
  const ConsentRecord({
    required this.version,
    required this.acceptedAt,
    required this.amountRupees,
  });

  /// Identifies the exact wording the user agreed to.
  final String version;
  final DateTime acceptedAt;

  /// The amount shown in that wording.
  final int amountRupees;

  Map<String, Object?> toJson() => {
    'version': version,
    'acceptedAt': acceptedAt.millisecondsSinceEpoch,
    'amountRupees': amountRupees,
  };

  static ConsentRecord? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final v = raw['version'], at = raw['acceptedAt'], a = raw['amountRupees'];
    if (v is! String || v.isEmpty || at is! int || a is! int) return null;
    return ConsentRecord(
      version: v,
      acceptedAt: DateTime.fromMillisecondsSinceEpoch(at),
      amountRupees: a,
    );
  }
}

/// One blocked app.
class AppRef {
  const AppRef(this.packageName, this.appName);
  final String packageName;
  final String appName;
}

/// One commitment covering one or more apps. Immutable; all times are
/// absolute timestamps.
class Commitment {
  const Commitment({
    required this.id,
    required this.apps,
    required this.startTime,
    required this.endTime,
    required this.durationMinutes,
    required this.commitmentAmount,
    required this.status,
    required this.createdAt,
    required this.emergencyLimit,
    required this.emergencyMinutes,
    this.emergencyAccessCount = 0,
    this.completedAt,
    this.lastEmergencyStart,
    this.lastEmergencyEnd,
    this.completionAcknowledged = false,
    this.payment,
    this.actualEndTime,
    this.integrityEvents = const [],
    this.ownerUserId,
    this.serverIssued = false,
    this.registrationKey,
    this.consent,
  });

  /// The user's acceptance of the payment condition (null for challenges
  /// started before 2.4).
  final ConsentRecord? consent;

  final String id;

  /// The apps blocked by this commitment (at least one).
  final List<AppRef> apps;
  final DateTime startTime;
  final DateTime endTime;
  final int durationMinutes;

  /// Simulated amount in rupees; 0 means none. Never charged.
  final int commitmentAmount;
  final CommitmentStatus status;

  /// How many emergency accesses were chosen for this commitment (0-3).
  final int emergencyLimit;

  /// Length of each emergency access, chosen when the commitment was made.
  final int emergencyMinutes;

  /// How many emergency accesses have been used so far.
  final int emergencyAccessCount;
  final DateTime createdAt;
  final DateTime? completedAt;
  final DateTime? lastEmergencyStart;
  final DateTime? lastEmergencyEnd;

  /// Whether the user has already seen the completion screen.
  final bool completionAcknowledged;

  /// Payment for ending early: absent until the user starts one.
  final PaymentRecord? payment;

  /// When the challenge really stopped, if it was ended early.
  final DateTime? actualEndTime;

  /// Protection interruptions recorded during this challenge, oldest first.
  final List<IntegrityEvent> integrityEvents;

  /// True while the last recorded event left the apps unprotected.
  bool get hasOpenGap {
    var open = false;
    for (final e in integrityEvents) {
      if (e.opensGap) open = true;
      if (e.closesGap) open = false;
    }
    return open;
  }

  /// True if this phone lost the challenge and restored it from the server.
  bool get restored =>
      integrityEvents.any((e) => e.type == IntegrityEvent.restoredOnDevice);

  /// How many separate times protection was interrupted.
  int get interruptionCount {
    var n = 0, open = false;
    for (final e in integrityEvents) {
      if (e.opensGap && !open) {
        open = true;
        n++;
      } else if (e.closesGap) {
        open = false;
      }
    }
    return n;
  }

  /// Time that was still left when the challenge was ended early.
  Duration get remainingAtEnd {
    final t = actualEndTime;
    if (t == null || !t.isBefore(endTime)) return Duration.zero;
    return endTime.difference(t);
  }

  /// User the backend says owns this challenge (null for records made
  /// before 2.3).
  final String? ownerUserId;

  /// True when the ID, times and amount were issued by a real server.
  /// False means they came from the local stand-in.
  final bool serverIssued;

  /// Idempotency key used to register this challenge with the backend.
  final String? registrationKey;

  /// The same challenge with terms as the backend states them. Used only
  /// when reconciling with the server; nothing in the UI can call this.
  Commitment withServerTerms({
    required DateTime startTime,
    required DateTime endTime,
    required int amountRupees,
    String? ownerUserId,
  }) => Commitment(
    id: id,
    apps: apps,
    startTime: startTime,
    endTime: endTime,
    durationMinutes: durationMinutes,
    commitmentAmount: amountRupees,
    status: status,
    createdAt: createdAt,
    emergencyLimit: emergencyLimit,
    emergencyMinutes: emergencyMinutes,
    emergencyAccessCount: emergencyAccessCount,
    completedAt: completedAt,
    lastEmergencyStart: lastEmergencyStart,
    lastEmergencyEnd: lastEmergencyEnd,
    completionAcknowledged: completionAcknowledged,
    payment: payment,
    actualEndTime: actualEndTime,
    integrityEvents: integrityEvents,
    ownerUserId: ownerUserId ?? this.ownerUserId,
    serverIssued: true,
    registrationKey: registrationKey,
    consent: consent,
  );

  /// ACTIVE or EMERGENCY: the commitment is still running.
  bool get isLive =>
      status == CommitmentStatus.active || status == CommitmentStatus.emergency;

  int get emergencyRemaining {
    final left = emergencyLimit - emergencyAccessCount;
    return left < 0 ? 0 : left;
  }

  List<String> get packageNames => [for (final a in apps) a.packageName];
  List<String> get appNames => [for (final a in apps) a.appName];

  /// A challenge this phone marked as completed although the server says it
  /// is still running (the phone's clock was wrong): back to active.
  Commitment reactivated() => Commitment(
    id: id,
    apps: apps,
    startTime: startTime,
    endTime: endTime,
    durationMinutes: durationMinutes,
    commitmentAmount: commitmentAmount,
    status: CommitmentStatus.active,
    createdAt: createdAt,
    emergencyLimit: emergencyLimit,
    emergencyMinutes: emergencyMinutes,
    emergencyAccessCount: emergencyAccessCount,
    completedAt: null,
    lastEmergencyStart: lastEmergencyStart,
    lastEmergencyEnd: lastEmergencyEnd,
    completionAcknowledged: false,
    payment: payment,
    actualEndTime: actualEndTime,
    integrityEvents: integrityEvents,
    ownerUserId: ownerUserId,
    serverIssued: true,
    registrationKey: registrationKey,
    consent: consent,
  );

  Commitment copyWith({
    CommitmentStatus? status,
    int? emergencyAccessCount,
    DateTime? completedAt,
    DateTime? lastEmergencyStart,
    DateTime? lastEmergencyEnd,
    bool? completionAcknowledged,
    PaymentRecord? payment,
    DateTime? actualEndTime,
    List<IntegrityEvent>? integrityEvents,
  }) => Commitment(
    id: id,
    apps: apps,
    startTime: startTime,
    endTime: endTime,
    durationMinutes: durationMinutes,
    commitmentAmount: commitmentAmount,
    createdAt: createdAt,
    emergencyLimit: emergencyLimit,
    emergencyMinutes: emergencyMinutes,
    status: status ?? this.status,
    emergencyAccessCount: emergencyAccessCount ?? this.emergencyAccessCount,
    completedAt: completedAt ?? this.completedAt,
    lastEmergencyStart: lastEmergencyStart ?? this.lastEmergencyStart,
    lastEmergencyEnd: lastEmergencyEnd ?? this.lastEmergencyEnd,
    completionAcknowledged:
        completionAcknowledged ?? this.completionAcknowledged,
    payment: payment ?? this.payment,
    actualEndTime: actualEndTime ?? this.actualEndTime,
    integrityEvents: integrityEvents ?? this.integrityEvents,
    ownerUserId: ownerUserId,
    serverIssued: serverIssued,
    registrationKey: registrationKey,
    consent: consent,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'packageNames': packageNames,
    'appNames': appNames,
    // Kept so data stays readable by versions before 2.0.
    'packageName': apps.first.packageName,
    'appName': apps.first.appName,
    'startTime': startTime.millisecondsSinceEpoch,
    'endTime': endTime.millisecondsSinceEpoch,
    'durationMinutes': durationMinutes,
    'commitmentAmount': commitmentAmount,
    'status': status.wire,
    'emergencyLimit': emergencyLimit,
    'emergencyMinutes': emergencyMinutes,
    'emergencyAccessCount': emergencyAccessCount,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'completedAt': completedAt?.millisecondsSinceEpoch,
    'lastEmergencyStart': lastEmergencyStart?.millisecondsSinceEpoch,
    'lastEmergencyEnd': lastEmergencyEnd?.millisecondsSinceEpoch,
    'completionAcknowledged': completionAcknowledged,
    'payment': payment?.toJson(),
    'actualEndTime': actualEndTime?.millisecondsSinceEpoch,
    'integrityEvents': [for (final e in integrityEvents) e.toJson()],
    'ownerUserId': ownerUserId,
    'serverIssued': serverIssued,
    'registrationKey': registrationKey,
    'consent': consent?.toJson(),
  };

  /// Throws [FormatException] if the saved record is not valid.
  /// Also reads records saved by versions before 2.0 (single app, no
  /// emergency settings).
  factory Commitment.fromJson(Map<String, Object?> j) {
    DateTime time(String key) {
      final v = j[key];
      if (v is! int || v <= 0) throw FormatException('Invalid $key');
      return DateTime.fromMillisecondsSinceEpoch(v);
    }

    DateTime? optTime(String key) => j[key] == null ? null : time(key);

    String text(String key) {
      final v = j[key];
      if (v is! String || v.isEmpty) throw FormatException('Invalid $key');
      return v;
    }

    int number(String key, {int? fallback}) {
      final v = j[key] ?? fallback;
      if (v is! int || v < 0) throw FormatException('Invalid $key');
      return v;
    }

    final List<AppRef> apps;
    final pkgs = j['packageNames'];
    if (pkgs is List) {
      final names = j['appNames'];
      if (pkgs.isEmpty || names is! List || names.length != pkgs.length) {
        throw const FormatException('Invalid app list');
      }
      apps = [
        for (var i = 0; i < pkgs.length; i++)
          if (pkgs[i] is String &&
              (pkgs[i] as String).isNotEmpty &&
              names[i] is String &&
              (names[i] as String).isNotEmpty)
            AppRef(pkgs[i] as String, names[i] as String)
          else
            throw const FormatException('Invalid app entry'),
      ];
    } else {
      apps = [AppRef(text('packageName'), text('appName'))];
    }

    final used = number('emergencyAccessCount');
    final c = Commitment(
      id: text('id'),
      apps: apps,
      startTime: time('startTime'),
      endTime: time('endTime'),
      durationMinutes: number('durationMinutes'),
      commitmentAmount: number('commitmentAmount'),
      status: CommitmentStatus.parse(j['status']),
      // Older records had no limit: give them the most the new rules allow.
      emergencyLimit: number('emergencyLimit', fallback: used > 3 ? used : 3),
      emergencyMinutes: number('emergencyMinutes', fallback: 5),
      emergencyAccessCount: used,
      createdAt: time('createdAt'),
      completedAt: optTime('completedAt'),
      lastEmergencyStart: optTime('lastEmergencyStart'),
      lastEmergencyEnd: optTime('lastEmergencyEnd'),
      completionAcknowledged: j['completionAcknowledged'] == true,
      payment: j['payment'] is Map
          ? PaymentRecord.fromJson(
              Map<String, Object?>.from(j['payment'] as Map),
            )
          : null,
      actualEndTime: optTime('actualEndTime'),
      integrityEvents: [
        for (final raw in (j['integrityEvents'] as List? ?? const []))
          ?IntegrityEvent.tryParse(raw),
      ],
      ownerUserId: j['ownerUserId'] as String?,
      serverIssued: j['serverIssued'] == true,
      registrationKey: j['registrationKey'] as String?,
      consent: ConsentRecord.tryParse(j['consent']),
    );
    if (!c.endTime.isAfter(c.startTime)) {
      throw const FormatException('endTime must be after startTime');
    }
    if ((c.lastEmergencyStart == null) != (c.lastEmergencyEnd == null)) {
      throw const FormatException('Incomplete emergency window');
    }
    return c;
  }
}
