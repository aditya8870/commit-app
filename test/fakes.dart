import 'dart:convert';

import 'package:app/core/backend.dart';
import 'package:app/core/clock.dart';
import 'package:app/core/commitment.dart';
import 'package:app/core/features.dart';
import 'package:app/core/payment.dart';
import 'package:app/data/commit_controller.dart';
import 'package:app/platform/platform_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeClock implements Clock {
  FakeClock([DateTime? start]) : time = start ?? DateTime(2026, 10, 3, 10);
  DateTime time;
  @override
  DateTime now() => time;
  void advance(Duration d) => time = time.add(d);
}

/// In-memory stand-in for Android. [disk] plays the role of SharedPreferences
/// and survives "restarts" (creating a new controller on the same bridge).
class FakeBridge implements PlatformBridge {
  String? disk;
  bool accessibility = true;
  bool battery = true;
  bool usage = true;

  /// Events the native side "recorded" and has not handed over yet.
  List<Map<String, Object?>> nativeEvents = [];
  bool overlay = true;
  Set<String> uninstalled = {};
  Set<String> notBlockable = {'com.commit.app', 'com.android.settings'};
  List<AppInfo> apps = const [
    AppInfo(packageName: 'com.instagram.android', appName: 'Instagram'),
    AppInfo(packageName: 'com.google.android.youtube', appName: 'YouTube'),
  ];
  String? launchAction;
  void Function(String action)? handler;
  int saves = 0;

  @override
  Future<String?> loadState() async => disk;
  @override
  Future<void> saveState(String json) async {
    disk = json;
    saves++;
  }

  @override
  Future<int> trustedNowMillis() async => 0;
  @override
  Future<void> reanchorClock() async {}

  /// Server times the app asked the native clock to adopt.
  final List<int> anchored = [];

  @override
  Future<void> anchorClock(int serverMillis) async =>
      anchored.add(serverMillis);
  @override
  Future<bool> isAccessibilityEnabled() async => accessibility;
  @override
  Future<void> openAccessibilitySettings() async =>
      accessibilitySettingsOpened++;
  @override
  Future<bool> isBatteryUnrestricted() async => battery;
  @override
  Future<void> openBatterySettings() async {}

  /// Pages the app asked the browser to open.
  final List<String> openedUrls = [];
  int accessibilitySettingsOpened = 0;

  @override
  Future<void> openUrl(String url) async => openedUrls.add(url);

  @override
  Future<String> drainIntegrityEvents() async {
    final out = jsonEncode(nativeEvents);
    nativeEvents = [];
    return out;
  }

  @override
  Future<bool> isUsageAccessEnabled() async => usage;
  @override
  Future<bool> isOverlayEnabled() async => overlay;
  @override
  Future<void> openUsageAccessSettings() async {}
  @override
  Future<void> openOverlaySettings() async {}
  @override
  Future<void> requestNotificationPermission() async {}
  @override
  Future<List<AppInfo>> installedApps() async => apps;
  @override
  Future<bool> isAppInstalled(String p) async => !uninstalled.contains(p);
  @override
  Future<bool> isBlockable(String p) async => !notBlockable.contains(p);
  @override
  Future<bool> launchApp(String p) async => true;
  @override
  Future<void> goHome() async {}
  @override
  Future<String> appVersion() async => '1.0.0';
  @override
  Future<String?> consumeLaunchAction() async {
    final a = launchAction;
    launchAction = null;
    return a;
  }

  @override
  void setLaunchActionHandler(void Function(String action)? h) => handler = h;
}

const instagram = 'com.instagram.android';

/// Scripted stand-in for a payment provider + backend, for tests only.
/// [server] is what the "backend" would answer for each reference.
class FakePayments implements PaymentService {
  @override
  bool isConfigured = true;

  /// What the checkout reports back to the app (may be wrong or missing).
  PaymentOutcome Function(PaymentRequest)? onPay;

  /// The truth, as the backend would report it.
  final Map<String, PaymentOutcome> server = {};
  bool verifyThrows = false;
  int payCalls = 0;
  int verifyCalls = 0;
  int charges = 0;

  /// Convenience: a checkout that really charges.
  void succeedWith(String txn, DateTime paidAt) {
    onPay = (r) {
      if (server[r.reference]?.status != PaymentStatus.successful) charges++;
      server[r.reference] = PaymentOutcome(
        PaymentStatus.successful,
        transactionId: txn,
        paidAt: paidAt,
      );
      return server[r.reference]!;
    };
  }

  @override
  Future<PaymentOutcome> pay(PaymentRequest request) async {
    payCalls++;
    return (onPay ?? (_) => const PaymentOutcome(PaymentStatus.failed))(
      request,
    );
  }

  @override
  Future<PaymentOutcome> verify(String reference) async {
    verifyCalls++;
    if (verifyThrows) throw Exception('offline');
    return server[reference] ?? const PaymentOutcome(PaymentStatus.notStarted);
  }
}

/// Test double for a REAL server: authoritative, with its own database and
/// clock. Used to prove the app obeys the server; it never ships.
class FakeBackend implements CommitBackend {
  FakeBackend(this.clock, this.pay);

  final FakeClock clock;

  /// The provider behind the server (its `server` map is the provider's truth).
  final FakePayments pay;

  @override
  bool isConnected = true;

  /// Set to simulate the server being unreachable.
  bool offline = false;

  /// What the server will issue, regardless of what the phone asks for.
  int? amountOverride;
  Duration serverClockOffset = Duration.zero;

  /// If set, the next authorisation is refused with this state.
  PaymentOutcome? denyWith;

  /// If set, returned as the answer to the next authorisation.
  PaymentAttemptDecision? decisionOverride;

  final Map<String, ChallengeTerms> byKey = {};
  final Map<String, ChallengeTerms> challenges = {};
  final Map<String, ServerChallengeStatus> statuses = {};
  final Map<String, PaymentAttemptDecision> decisions = {};
  final List<String> registrationKeys = [];
  final List<String> attemptKeys = [];
  int attempts = 0;
  int signIns = 0;
  String? lastInstallId;

  void _net() {
    if (offline) throw Exception('server unreachable');
  }

  static String ref(String id) => 'srv-order-$id';

  @override
  Future<Identity> signIn({required String installId}) async {
    _net();
    signIns++;
    lastInstallId = installId;
    return Identity(
      userId: 'user-42',
      deviceId: installId,
      isAuthenticated: true,
    );
  }

  @override
  Future<ChallengeTerms> registerChallenge(
    ChallengeRequest request, {
    required String idempotencyKey,
  }) async {
    _net();
    registrationKeys.add(idempotencyKey);
    final again = byKey[idempotencyKey];
    if (again != null) return again;
    final start = clock.time.add(serverClockOffset);
    final terms = ChallengeTerms(
      challengeId: 'srv-ch-${challenges.length + 1}',
      ownerUserId: 'user-42',
      startTime: start,
      endTime: start.add(Duration(minutes: request.durationMinutes)),
      amountRupees: amountOverride ?? request.amountRupees,
      authoritative: true,
    );
    byKey[idempotencyKey] = terms;
    challenges[terms.challengeId] = terms;
    statuses[terms.challengeId] = ServerChallengeStatus.active;
    requests.add(request);
    requestByChallenge[terms.challengeId] = request;
    if (dropNextReply) {
      dropNextReply = false;
      throw Exception('connection lost after the server saved the challenge');
    }
    return terms;
  }

  /// Requests the server received, including ones whose answer was lost.
  final List<ChallengeRequest> requests = [];
  final Map<String, ChallengeRequest> requestByChallenge = {};
  final Map<String, int> emergencyUsed = {};
  final List<ChallengeEvent> events = [];

  /// Simulates "the server did the work but the reply never arrived".
  bool dropNextReply = false;

  @override
  Future<ChallengeTerms?> registrationResult(String idempotencyKey) async {
    _net();
    return byKey[idempotencyKey];
  }

  @override
  Future<ServerChallenge?> currentChallenge() async {
    _net();
    for (final t in challenges.values) {
      if (statuses[t.challengeId] != ServerChallengeStatus.active) continue;
      final r = requestByChallenge[t.challengeId]!;
      return ServerChallenge(
        terms: t,
        status: ServerChallengeStatus.active,
        payment: pay.server[ref(t.challengeId)],
        details: ChallengeDetails(
          apps: r.apps,
          durationMinutes: r.durationMinutes,
          emergencyLimit: r.emergencyLimit,
          emergencyMinutes: r.emergencyMinutes,
          emergencyUsed: emergencyUsed[t.challengeId] ?? 0,
          consent: r.consent,
        ),
      );
    }
    return null;
  }

  @override
  Future<void> reportEvents(List<ChallengeEvent> batch) async {
    _net();
    for (final e in batch) {
      if (events.any((x) => x.eventId == e.eventId)) continue; // de-duplicate
      events.add(e);
      if (e.type == ChallengeEvent.emergencyUsed) {
        emergencyUsed[e.challengeId] = (emergencyUsed[e.challengeId] ?? 0) + 1;
      }
    }
  }

  @override
  Future<ServerChallenge?> fetchChallenge(String challengeId) async {
    _net();
    final t = challenges[challengeId];
    if (t == null) return null;
    final p = pay.server[ref(challengeId)];
    return ServerChallenge(
      terms: t,
      status: statuses[challengeId]!,
      payment: p,
    );
  }

  @override
  Future<PaymentAttemptDecision> authorizePaymentAttempt(
    String challengeId, {
    required String idempotencyKey,
  }) async {
    _net();
    attemptKeys.add(idempotencyKey);
    final again = decisions[idempotencyKey];
    if (again != null) return again;
    final current = await paymentStatus(challengeId);
    final PaymentAttemptDecision d;
    if (decisionOverride != null) {
      d = decisionOverride!;
      decisionOverride = null;
    } else if (denyWith != null) {
      d = PaymentAttemptDecision.denied(denyWith!);
    } else if (current.status == PaymentStatus.successful ||
        current.status.mustVerifyBeforeRetry) {
      d = PaymentAttemptDecision.denied(current);
    } else {
      attempts++;
      d = PaymentAttemptDecision.allowed(
        reference: ref(challengeId),
        amountRupees: challenges[challengeId]!.amountRupees,
        attempt: attempts,
        expiresAt: challenges[challengeId]!.endTime,
      );
    }
    decisions[idempotencyKey] = d;
    return d;
  }

  @override
  Future<PaymentOutcome> paymentStatus(String challengeId) async {
    _net();
    return pay.server[ref(challengeId)] ??
        const PaymentOutcome(PaymentStatus.notStarted);
  }
}

Future<CommitController> boot(
  FakeBridge bridge,
  FakeClock clock, {
  PaymentService? payments,
  CommitBackend? backend,
}) async {
  final c = CommitController(
    bridge: bridge,
    clock: clock,
    payments: payments ?? const UnconfiguredPaymentService(),
    backend: backend,
  );
  await c.load();
  return c;
}

const youtube = 'com.google.android.youtube';

ChallengeRequest sampleRequest(FakeClock clock, {int amount = 100}) =>
    ChallengeRequest(
      apps: const [AppRef(instagram, 'Instagram')],
      durationMinutes: 60,
      amountRupees: amount,
      emergencyLimit: 0,
      emergencyMinutes: 5,
      consent: ConsentRecord(
        version: 'test',
        acceptedAt: clock.time,
        amountRupees: amount,
      ),
    );

extension Shortcuts on CommitController {
  /// One-app commitment on Instagram.
  Future<void> startInstagram({
    int minutes = 1440,
    int amount = 100,
    int emergencyLimit = 2,
    int emergencyMinutes = 5,
  }) => createCommitment(
    consentAccepted: true,
    apps: const [AppRef(instagram, 'Instagram')],
    durationMinutes: minutes,
    amount: amount,
    emergencyLimit: emergencyLimit,
    emergencyMinutes: emergencyMinutes,
  );
}

/// For tests of the dormant payment code and its screens. The released app
/// runs with payments off; these tests switch them on for their own duration.
void withDormantPayments() {
  Features.payments = true;
  addTearDown(() => Features.payments = false);
}
