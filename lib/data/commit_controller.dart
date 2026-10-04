import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/backend.dart';
import '../core/clock.dart';
import '../core/commitment.dart';
import '../core/commitment_engine.dart';
import '../core/features.dart';
import '../core/payment.dart';
import '../platform/platform_bridge.dart';
import 'standin_backend.dart';

/// The app's single source of truth in Dart.
///
/// Holds every commitment, persists them as one JSON document through the
/// [PlatformBridge] (native SharedPreferences, which the blocking service also
/// reads), and applies the time-based transitions from [CommitmentEngine].
class CommitController extends ChangeNotifier {
  CommitController({
    required this.bridge,
    required this.clock,
    this.payments = const UnconfiguredPaymentService(),
    CommitBackend? backend,
  }) : backend = backend ?? StandInBackend(clock: clock, payments: payments) {
    final b = this.backend;
    if (b is StandInBackend) b.localLookup = byId;
  }

  /// Decides everything the phone must not decide: challenge ID, amount, end
  /// time, payment reference and payment status. See lib/core/backend.dart.
  /// Until a real server exists this is the local [StandInBackend].
  final CommitBackend backend;

  /// Stable identifier of this install, created once and saved.
  String installId = '';

  /// Who the backend says we are. Not authenticated with the stand-in.
  Identity? identity;

  /// While a provider checkout is open: until when payment apps are let
  /// through the blocker (see LockState in NativeStore.kt). Null otherwise.
  DateTime? checkoutUntil;

  /// A challenge registration whose result is not stored yet (U1).
  PendingRegistration? pendingRegistration;

  /// Events waiting to be sent to the backend (U3). Only filled for
  /// challenges a real server knows about.
  List<ChallengeEvent> outbox = [];
  static const _maxOutbox = 500;

  /// Shown once: something the app did on its own that the user should know.
  String? notice;

  /// Longest a checkout may keep payment apps unblocked.
  static const checkoutWindow = Duration(minutes: 10);

  /// A challenge gets this many checkout windows; later attempts still work
  /// but payment apps the user chose to block stay blocked.
  static const maxCheckoutWindows = 5;

  /// Where a real payment provider plugs in. See lib/core/payment.dart.
  final PaymentService payments;

  /// True while a pay/verify call is running, so a second tap cannot start
  /// another one.
  bool paymentBusy = false;

  final PlatformBridge bridge;
  final Clock clock;

  static const _schemaVersion = 2;

  List<Commitment> _items = [];
  bool loaded = false;
  bool onboarded = false;

  /// Primary detector: reacts the moment the locked app opens.
  bool accessibilityEnabled = false;

  /// Backup detector, part 1: lets the backup see which app is in front.
  bool usageAccessEnabled = false;

  /// Backup detector, part 2: lets the backup show the lock screen.
  bool overlayEnabled = false;

  /// Battery optimisation is off for Commit, so Android is less likely to
  /// stop the backup service.
  bool batteryUnrestricted = false;

  /// The user tapped "Agree" on the Accessibility disclosure. Without it the
  /// app never sends the user to the Accessibility settings.
  bool accessibilityConsent = false;

  bool get backupEnabled => usageAccessEnabled && overlayEnabled;

  /// Blocking works if at least one detector can run.
  bool get protectionEnabled => accessibilityEnabled || backupEnabled;

  /// Both detectors are available: turning one off does not stop blocking.
  bool get fullProtection => accessibilityEnabled && backupEnabled;

  /// What must be on before a challenge can start: something that can block
  /// the apps. Commit never stops the user from switching it off, removing
  /// the app or clearing its data; those are recorded, not prevented.
  bool get readyToStart => protectionEnabled;

  /// Records the user's "Agree" on the Accessibility disclosure.
  Future<void> acceptAccessibilityDisclosure() async {
    accessibilityConsent = true;
    await _save();
    notifyListeners();
  }

  /// The explicit state of the running challenge, or null if none is running.
  ChallengeState? get activeState {
    final a = active;
    return a == null
        ? null
        : CommitmentEngine.stateOf(a, now, protectionOk: protectionEnabled);
  }

  String get protectionLabel => fullProtection
      ? 'Full protection'
      : accessibilityEnabled
      ? 'Primary only (backup off)'
      : backupEnabled
      ? 'Backup only (primary off)'
      : 'Disabled';

  /// Names of committed apps that have been uninstalled since.
  List<String> missingApps = const [];

  /// App icons by package name, loaded once for display.
  Map<String, Uint8List> icons = const {};
  bool _iconsRequested = false;

  /// Set when saved data had to be repaired; shown once to the user.
  String? loadWarning;

  /// True after emergency access ended and the app was locked again,
  /// until the user has seen the notice.
  bool relockNotice = false;

  Timer? _ticker;

  // ---------------------------------------------------------------- queries

  DateTime get now => clock.now();

  Commitment? get active {
    for (final c in _items) {
      if (c.isLive) return c;
    }
    return null;
  }

  /// A finished commitment whose completion screen has not been shown yet.
  Commitment? get pendingCompletion {
    Commitment? latest;
    for (final c in _items) {
      final finished =
          c.status == CommitmentStatus.completed ||
          c.status == CommitmentStatus.endedEarly;
      if (finished && !c.completionAcknowledged) {
        if (latest == null || c.endTime.isAfter(latest.endTime)) latest = c;
      }
    }
    return latest;
  }

  /// Newest first.
  List<Commitment> get history =>
      [..._items]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  CommitmentStats get stats => CommitmentEngine.stats(_items);

  Commitment? byId(String id) {
    for (final c in _items) {
      if (c.id == id) return c;
    }
    return null;
  }

  // ------------------------------------------------------------- lifecycle

  Future<void> load() async {
    await _syncClock();
    String? raw;
    try {
      raw = await bridge.loadState();
    } catch (_) {
      loadWarning = 'Saved data could not be read.';
    }
    _items = [];
    var repaired = false;
    if (raw != null && raw.isNotEmpty) {
      try {
        final doc = jsonDecode(raw) as Map<String, Object?>;
        onboarded = doc['onboarded'] == true;
        accessibilityConsent = doc['accessibilityConsent'] == true;
        final savedInstall = doc['installId'];
        if (savedInstall is String && savedInstall.isNotEmpty) {
          installId = savedInstall;
        }
        pendingRegistration = PendingRegistration.tryParse(
          doc['pendingRegistration'],
        );
        outbox = [
          for (final raw in (doc['outbox'] as List? ?? const []))
            ?ChallengeEvent.tryParse(raw),
        ];
        final checkout = doc['checkout'];
        if (checkout is Map && checkout['until'] is int) {
          checkoutUntil = DateTime.fromMillisecondsSinceEpoch(
            checkout['until'] as int,
          );
        }
        for (final entry in (doc['commitments'] as List? ?? const [])) {
          try {
            _items.add(
              Commitment.fromJson(Map<String, Object?>.from(entry as Map)),
            );
          } catch (_) {
            repaired = true; // skip the invalid record, keep the rest
          }
        }
      } catch (_) {
        repaired = true;
      }
    }
    // Enforce the one-active-commitment rule on whatever was on disk.
    final live = _items.where((c) => c.isLive).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (live.length > 1) {
      for (final extra in live.skip(1)) {
        _replace(extra.copyWith(status: CommitmentStatus.cancelled));
      }
      repaired = true;
    }
    if (repaired) {
      loadWarning = 'Some saved data was invalid and has been repaired. Valid commitments were kept.';
    }
    var changed = _normalize();
    if (installId.isEmpty) {
      installId = IdempotencyKey.generate();
      changed = true;
    }
    // Without a real server nothing can exist outside the phone, so an
    // unfinished registration is simply dropped.
    if (pendingRegistration != null && !backend.isConnected) {
      pendingRegistration = null;
      changed = true;
    }
    // A checkout window never survives a restart: nothing is open any more.
    if (checkoutUntil != null) {
      checkoutUntil = null;
      changed = true;
    }
    if (repaired || changed) await _save();
    try {
      identity = await backend.signIn(installId: installId);
    } catch (_) {
      identity = null; // offline: identity is established on a later sync
    }
    await refreshEnvironment();
    loaded = true;
    notifyListeners();
    unawaited(syncWithBackend());
  }

  /// Starts the 1-second UI refresh. State never depends on this timer:
  /// each tick only re-derives state from timestamps.
  void startTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  int _ticks = 0;

  void tick() {
    if (!loaded) return;
    _ticks++;
    if (_ticks % 20 == 0) unawaited(_syncClock());
    if (_ticks % 5 == 0 && active != null) {
      unawaited(refreshEnvironment().then((_) => notifyListeners()));
    }
    // A payment whose result is unknown is re-checked while the app is open,
    // so it cannot sit unresolved until the user happens to tap something.
    if (_ticks % 15 == 0) {
      unawaited(reconcilePayment());
      unawaited(flushOutbox());
    }
    final changed = _normalize();
    if (changed) unawaited(_save());
    if (changed || active != null) notifyListeners();
  }

  /// Call when the app returns to the foreground.
  Future<void> onResume() async {
    if (!loaded) return;
    await _syncClock();
    if (_normalize()) await _save();
    await refreshEnvironment();
    notifyListeners();
    unawaited(syncWithBackend());
  }

  /// Re-reads things that can change outside the app.
  Future<void> refreshEnvironment() async {
    try {
      accessibilityEnabled = await bridge.isAccessibilityEnabled();
      usageAccessEnabled = await bridge.isUsageAccessEnabled();
      overlayEnabled = await bridge.isOverlayEnabled();
      batteryUnrestricted = await bridge.isBatteryUnrestricted();
    } catch (_) {
      accessibilityEnabled = false;
      usageAccessEnabled = false;
      overlayEnabled = false;
    }
    final a = active;
    final missing = <String>[];
    if (a != null) {
      for (final app in a.apps) {
        try {
          if (!await bridge.isAppInstalled(app.packageName)) {
            missing.add(app.appName);
          }
        } catch (_) {}
      }
    }
    missingApps = missing;
    await _trackProtection();
  }

  /// Pulls natively recorded interruptions onto the challenge they belong to
  /// and records when protection is lost or restored. Never charges, never
  /// ends a challenge.
  Future<void> _trackProtection() async {
    var changed = false;
    try {
      final raw = jsonDecode(await bridge.drainIntegrityEvents());
      if (raw is List) {
        for (final item in raw) {
          final e = IntegrityEvent.tryParse(item);
          if (e != null && _attach(e)) changed = true;
        }
      }
    } catch (_) {
      // The log is best-effort.
    }
    final a = active;
    if (a != null) {
      final now = clock.now();
      if (!protectionEnabled && !a.hasOpenGap) {
        changed =
            _attach(IntegrityEvent(IntegrityEvent.protectionLost, now)) ||
            changed;
      } else if (protectionEnabled && a.hasOpenGap) {
        changed =
            _attach(IntegrityEvent(IntegrityEvent.protectionRestored, now)) ||
            changed;
      }
    }
    if (changed) await _save();
  }

  /// Adds [e] to the challenge that was running at that moment.
  bool _attach(IntegrityEvent e) {
    for (final c in _items) {
      final end = c.actualEndTime ?? c.endTime;
      if (e.at.isBefore(c.startTime) || !e.at.isBefore(end)) continue;
      if (c.status == CommitmentStatus.cancelled) continue;
      final dup = c.integrityEvents.any(
        (x) => x.type == e.type && x.at.difference(e.at).inSeconds.abs() < 2,
      );
      if (dup) return false;
      // Opening an already open gap, or closing a closed one, adds nothing.
      if (e.opensGap && c.hasOpenGap && e.type != IntegrityEvent.forceStopped) {
        return false;
      }
      if (e.closesGap && !c.hasOpenGap) return false;
      final list = [...c.integrityEvents, e]
        ..sort((a, b) => a.at.compareTo(b.at));
      final updated = c.copyWith(integrityEvents: list);
      _replace(updated);
      _queueEvent(updated, e.type, e.at);
      return true;
    }
    return false;
  }

  /// Loads app icons in the background the first time they are needed.
  void ensureIcons() {
    if (_iconsRequested) return;
    _iconsRequested = true;
    bridge
        .installedApps()
        .then((apps) {
          icons = {
            for (final a in apps)
              if (a.icon != null) a.packageName: a.icon!,
          };
          notifyListeners();
        })
        .catchError((_) {
          _iconsRequested = false;
        });
  }

  Future<void> refreshProtection() async {
    await refreshEnvironment();
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // --------------------------------------------------------------- actions

  Future<void> completeOnboarding() async {
    onboarded = true;
    await _save();
    notifyListeners();
  }

  /// Creates and starts one commitment covering all [apps]. Refused while
  /// another one is running.
  Future<Commitment> createCommitment({
    required List<AppRef> apps,
    required int durationMinutes,
    required int amount,
    required bool consentAccepted,
    int emergencyLimit = 0,
    int emergencyMinutes = CommitmentEngine.defaultEmergencyMinutes,
  }) async {
    if (!consentAccepted) {
      throw const CommitmentException(CommitmentError.consentRequired);
    }
    if (_normalize()) await _save();
    if (active != null) {
      throw const CommitmentException(CommitmentError.duplicateActive);
    }
    if (apps.isEmpty) throw const CommitmentException(CommitmentError.noApps);
    for (final app in apps) {
      var blockable = false;
      try {
        blockable = await bridge.isBlockable(app.packageName);
      } catch (_) {}
      if (!blockable) {
        throw const CommitmentException(CommitmentError.invalidApp);
      }
    }

    // No commitment is running, so it is safe to re-sync with the wall clock.
    try {
      await bridge.reanchorClock();
    } catch (_) {}
    await _syncClock();
    if (active != null) {
      throw const CommitmentException(CommitmentError.duplicateActive);
    }
    // An earlier registration whose result is unknown must be settled first,
    // otherwise two challenges could exist on the server.
    if (pendingRegistration != null) {
      await resumePendingRegistration();
      if (pendingRegistration != null) {
        throw const CommitmentException(CommitmentError.registrationUnresolved);
      }
      if (active != null) {
        throw const CommitmentException(CommitmentError.duplicateActive);
      }
    }

    // Validate locally first, so nothing invalid is ever sent or saved.
    CommitmentEngine.create(
      id: 'validation-only',
      apps: apps,
      durationMinutes: durationMinutes,
      amount: amount,
      emergencyLimit: emergencyLimit,
      emergencyMinutes: emergencyMinutes,
      now: clock.now(),
    );

    final request = ChallengeRequest(
      apps: apps,
      durationMinutes: durationMinutes,
      amountRupees: amount,
      emergencyLimit: emergencyLimit,
      emergencyMinutes: emergencyMinutes,
      consent: ConsentRecord(
        version: CommitmentEngine.consentVersion,
        acceptedAt: clock.now(),
        amountRupees: amount,
      ),
    );

    // Save the request and its key BEFORE asking the backend. If the app
    // dies or the connection drops now, the next start asks the backend what
    // became of this key instead of leaving an orphan challenge behind.
    final registrationKey = IdempotencyKey.generate();
    pendingRegistration = PendingRegistration(
      idempotencyKey: registrationKey,
      request: request,
      createdAt: clock.now(),
    );
    await _save();

    // The backend fixes the ID, owner, start and end time and the amount.
    // The phone only keeps a copy of what it was told.
    final ChallengeTerms terms;
    try {
      terms = await backend.registerChallenge(
        request,
        idempotencyKey: registrationKey,
      );
    } catch (_) {
      // Unknown whether the server created it: keep the pending record.
      throw const CommitmentException(CommitmentError.serverUnavailable);
    }
    final c = _adoptRegistration(terms, request, registrationKey);
    relockNotice = false;
    missingApps = const [];
    await _save();
    // The 'Commitment active' notification is optional; blocking works without it.
    unawaited(bridge.requestNotificationPermission().catchError((_) {}));
    notifyListeners();
    return c;
  }

  /// Turns the backend's terms into the phone's copy of the challenge and
  /// clears the pending registration.
  Commitment _adoptRegistration(
    ChallengeTerms terms,
    ChallengeRequest request,
    String registrationKey,
  ) {
    if (terms.challengeId.isEmpty ||
        !terms.endTime.isAfter(terms.startTime) ||
        byId(terms.challengeId) != null) {
      pendingRegistration = null;
      unawaited(_save());
      throw const CommitmentException(CommitmentError.invalidServerTerms);
    }
    final c = CommitmentEngine.create(
      id: terms.challengeId,
      apps: request.apps,
      durationMinutes: request.durationMinutes,
      amount: terms.amountRupees,
      emergencyLimit: request.emergencyLimit,
      emergencyMinutes: request.emergencyMinutes,
      now: terms.startTime,
      endTime: terms.endTime,
      ownerUserId: terms.ownerUserId,
      serverIssued: terms.authoritative,
      registrationKey: registrationKey,
      consent: request.consent,
    );
    _items.add(c);
    pendingRegistration = null;
    return c;
  }

  /// Settles a registration whose result was never stored: asks the backend
  /// whether that request created a challenge. If it did, the challenge is
  /// adopted; if not, the request is dropped. Never creates a challenge.
  Future<void> resumePendingRegistration() async {
    final p = pendingRegistration;
    if (p == null) return;
    final ChallengeTerms? terms;
    try {
      terms = await backend.registrationResult(p.idempotencyKey);
    } catch (_) {
      return; // still unknown; try again later
    }
    if (terms == null) {
      pendingRegistration = null;
      await _save();
      return;
    }
    try {
      _adoptRegistration(terms, p.request, p.idempotencyKey);
      notice =
          'A challenge you started earlier was confirmed and is now active.';
    } on CommitmentException {
      // Invalid or already known: nothing to adopt.
    }
    _normalize();
    await _save();
    notifyListeners();
  }

  /// After reinstall, device change or cleared data: if the signed-in user
  /// has a running challenge the phone does not know, rebuild it from the
  /// backend so it keeps being blocked and its payment state is intact.
  Future<void> restoreFromBackend() async {
    if (!backend.isConnected || active != null) return;
    if (pendingRegistration != null) return;
    final ServerChallenge? server;
    try {
      server = await backend.currentChallenge();
    } catch (_) {
      return;
    }
    // This phone marked the challenge complete, but the server (whose clock
    // decides) says it is still running: the phone's clock was wrong. Put it
    // back, so a changed clock is never a way out.
    final known = server == null ? null : byId(server.terms.challengeId);
    if (server != null &&
        known != null &&
        server.status == ServerChallengeStatus.active &&
        known.status == CommitmentStatus.completed &&
        server.terms.endTime.isAfter(clock.now())) {
      final revived = known.reactivated();
      _replace(revived);
      _queueEvent(revived, ChallengeEvent.clockJump, clock.now());
      notice =
          'Your challenge is still running. The time on this phone was wrong.';
      _normalize();
      await _save();
      notifyListeners();
      return;
    }
    final d = server?.details;
    if (server == null ||
        d == null ||
        d.apps.isEmpty ||
        server.status != ServerChallengeStatus.active ||
        byId(server.terms.challengeId) != null ||
        !server.terms.endTime.isAfter(server.terms.startTime)) {
      return;
    }
    final t = server.terms;
    _items.add(
      Commitment(
        id: t.challengeId,
        apps: List.unmodifiable(d.apps),
        startTime: t.startTime,
        endTime: t.endTime,
        durationMinutes: d.durationMinutes,
        commitmentAmount: t.amountRupees,
        status: CommitmentStatus.active,
        createdAt: t.startTime,
        emergencyLimit: d.emergencyLimit,
        emergencyMinutes: d.emergencyMinutes,
        emergencyAccessCount: d.emergencyUsed,
        ownerUserId: t.ownerUserId,
        serverIssued: true,
        consent: d.consent,
        // The phone had lost this challenge. What happened meanwhile is
        // unknown, so it can no longer count as cleanly kept.
        integrityEvents: [
          IntegrityEvent(IntegrityEvent.restoredOnDevice, clock.now()),
        ],
      ),
    );
    _normalize();
    final restored = byId(t.challengeId);
    if (restored != null) {
      _queueEvent(restored, ChallengeEvent.restoredOnDevice, clock.now());
    }
    notice = 'Your running challenge was restored.';
    await _save();
    notifyListeners();
    final paid = server.payment;
    if (paid != null) await _applyOutcome(t.challengeId, paid);
  }

  // ------------------------------------------------- events for the backend

  /// Queues an event for the backend's record. Only for challenges a real
  /// server knows about; with the stand-in there is nobody to tell.
  void _queueEvent(Commitment c, String type, DateTime at) {
    if (!c.serverIssued || outbox.length >= _maxOutbox) return;
    outbox.add(
      ChallengeEvent(
        eventId: IdempotencyKey.generate(),
        challengeId: c.id,
        type: type,
        at: at,
      ),
    );
  }

  /// Sends queued events. Anything not accepted stays queued.
  Future<void> flushOutbox() async {
    if (!backend.isConnected || outbox.isEmpty || _flushing) return;
    _flushing = true;
    final batch = [...outbox];
    try {
      await backend.reportEvents(batch);
      final sent = {for (final e in batch) e.eventId};
      outbox.removeWhere((e) => sent.contains(e.eventId));
      await _save();
    } catch (_) {
      // Offline or refused: keep them for the next attempt.
    } finally {
      _flushing = false;
    }
  }

  bool _flushing = false;

  /// Uses one emergency access. Refused if one is already running or none
  /// are left.
  Future<Commitment> startEmergency() async {
    await _syncClock();
    if (_normalize()) await _save();
    final a = active;
    if (a == null) {
      throw const CommitmentException(CommitmentError.noActiveCommitment);
    }
    final updated = CommitmentEngine.startEmergency(a, clock.now());
    _replace(updated);
    _queueEvent(updated, ChallengeEvent.emergencyUsed, clock.now());
    relockNotice = false;
    try {
      await _save();
    } catch (_) {
      _replace(a);
      rethrow;
    }
    notifyListeners();
    return updated;
  }

  // --------------------------------------------------- ending early (payment)

  /// Pays the Commitment Amount and, ONLY if the payment is verified, ends
  /// the challenge. In every other outcome the challenge stays active.
  ///
  /// Safe against double charging: the reference is fixed per challenge, the
  /// attempt is saved before the provider is opened, and any attempt that may
  /// have moved money is re-verified instead of being charged again.
  Future<PaymentOutcome> endChallengeWithPayment() async {
    // This release has no financial consequences: nothing is asked of the
    // server and nothing can be charged.
    if (!Features.payments) {
      throw const CommitmentException(CommitmentError.endEarlyUnavailable);
    }
    if (paymentBusy) {
      throw const CommitmentException(CommitmentError.paymentInProgress);
    }
    // Set before the first await, so a second tap can never get past here.
    paymentBusy = true;
    notifyListeners();
    try {
      await _syncClock();
      if (_normalize()) await _save();
      final a = active;
      if (a == null) {
        throw const CommitmentException(CommitmentError.noActiveCommitment);
      }
      if (a.commitmentAmount <= 0) {
        throw const CommitmentException(CommitmentError.noAmount);
      }

      // 1. Unknown outcome of an earlier attempt: ONLY ask the backend. This
      //    path never opens a checkout.
      final previous = a.payment;
      if (previous != null && previous.status.mustVerifyBeforeRetry) {
        return await _applyOutcome(a.id, await _status(a.id));
      }
      if (!CommitmentEngine.canEndEarly(a, clock.now())) {
        throw const CommitmentException(CommitmentError.endingSoon);
      }

      // 2. A new attempt, first or retry. Save it as INITIATED with its
      //    idempotency key BEFORE anything leaves the phone, so a crash or a
      //    closed app is reconciled on the next start.
      final key = IdempotencyKey.generate();
      final started = clock.now();
      await _setPayment(
        a.id,
        PaymentRecord(
          reference: previous?.reference ?? '',
          amountRupees: previous?.amountRupees ?? a.commitmentAmount,
          status: PaymentStatus.initiated,
          initiatedAt: started,
          updatedAt: started,
          idempotencyKey: key,
          attempt: previous?.attempt ?? 0,
          transactionId: previous?.transactionId,
        ),
      );

      // 3. No checkout without the backend's permission. It checks the
      //    existing payment first, so a payment that went through after the
      //    app was told "failed" or "cancelled" is found here, not charged
      //    again.
      final PaymentAttemptDecision decision;
      try {
        decision = await backend.authorizePaymentAttempt(
          a.id,
          idempotencyKey: key,
        );
      } catch (_) {
        return await _applyOutcome(
          a.id,
          const PaymentOutcome(PaymentStatus.networkError),
        );
      }
      if (!decision.allowed) {
        return await _applyOutcome(a.id, decision.current!);
      }

      // An authorisation that has already run out is not used.
      final expiry = decision.expiresAt;
      if (expiry != null && !clock.now().isBefore(expiry)) {
        return await _applyOutcome(
          a.id,
          const PaymentOutcome(
            PaymentStatus.cancelled,
            message: 'This payment attempt expired before it started.',
          ),
        );
      }

      // 4. Reference and amount are the backend's, not the phone's.
      final reference = decision.reference!;
      final amount = decision.amountRupees!;
      await _setPayment(
        a.id,
        byId(a.id)!.payment!.copyWith(
          reference: reference,
          amountRupees: amount,
          attempt: decision.attempt,
          expiresAt: decision.expiresAt,
        ),
      );

      // 5. Open the provider's checkout. While it is open, payment apps the
      //    user chose to block are let through so the payment can be made.
      PaymentOutcome paid;
      await _openCheckoutWindow(decision.attempt);
      try {
        paid = await payments.pay(
          PaymentRequest(
            reference: reference,
            challengeId: a.id,
            amountRupees: amount,
            description: 'Commit: end challenge early',
          ),
        );
      } catch (_) {
        paid = const PaymentOutcome(PaymentStatus.networkError);
      } finally {
        await _closeCheckoutWindow();
      }

      // 6. Whatever the checkout said, the backend has the final word.
      return await _applyOutcome(a.id, await _confirm(a.id, paid));
    } finally {
      paymentBusy = false;
      notifyListeners();
    }
  }

  /// Turns what the checkout reported into what may be stored: the backend's
  /// answer wins whenever it knows more.
  Future<PaymentOutcome> _confirm(String id, PaymentOutcome reported) async {
    final server = await _status(id);
    switch (server.status) {
      case PaymentStatus.successful:
      case PaymentStatus.pending:
        return server;
      case PaymentStatus.networkError:
        // Could not ask. Nothing the checkout said can be relied on yet.
        return reported.status == PaymentStatus.failed ||
                reported.status == PaymentStatus.cancelled
            ? PaymentOutcome(
                PaymentStatus.networkError,
                message: reported.message,
              )
            : PaymentOutcome(
                reported.status == PaymentStatus.successful
                    ? PaymentStatus.networkError
                    : reported.status,
                message: reported.message ?? server.message,
              );
      default:
        // The backend has no payment. A checkout "success" is therefore
        // unverified; anything else is kept as the checkout described it.
        return reported.status == PaymentStatus.successful
            ? PaymentOutcome(
                PaymentStatus.verificationFailed,
                message: server.message,
              )
            : PaymentOutcome(reported.status, message: reported.message);
    }
  }

  /// After a restart or when the app comes back: bring the phone's copy in
  /// line with the backend. Never charges and never opens a checkout.
  Future<void> syncWithBackend() async {
    if (paymentBusy) return;
    if (identity == null && installId.isNotEmpty) {
      try {
        identity = await backend.signIn(installId: installId);
      } catch (_) {}
    }
    await resumePendingRegistration();
    await restoreFromBackend();
    await _adoptServerChallenge();
    await reconcilePayment();
    await flushOutbox();
  }

  /// With a real server: its terms and status replace the phone's copy.
  Future<void> _adoptServerChallenge() async {
    if (!backend.isConnected) return;
    final a = active;
    if (a == null) return;
    final ServerChallenge? server;
    try {
      server = await backend.fetchChallenge(a.id);
    } catch (_) {
      return; // offline: keep blocking on the last known terms
    }
    if (server == null) return;
    var c = a;
    final t = server.terms;
    if (t.endTime != c.endTime ||
        t.startTime != c.startTime ||
        t.amountRupees != c.commitmentAmount ||
        !c.serverIssued) {
      if (t.endTime.isAfter(t.startTime)) {
        c = c.withServerTerms(
          startTime: t.startTime,
          endTime: t.endTime,
          amountRupees: t.amountRupees,
          ownerUserId: t.ownerUserId,
        );
        _replace(c);
      }
    }
    if (server.status == ServerChallengeStatus.cancelled) {
      _replace(c.copyWith(status: CommitmentStatus.cancelled));
    }
    // The server's clock decides the lifecycle. If it says the challenge is
    // over, it is over, even if this phone's clock is behind.
    if (server.status == ServerChallengeStatus.completed && c.isLive) {
      _replace(
        c.copyWith(status: CommitmentStatus.completed, completedAt: c.endTime),
      );
      relockNotice = false;
    }
    if (server.status == ServerChallengeStatus.endedEarly &&
        c.isLive &&
        server.payment == null) {
      _replace(
        c.copyWith(
          status: CommitmentStatus.endedEarly,
          actualEndTime: server.actualEndTime ?? clock.now(),
        ),
      );
      relockNotice = false;
    }
    _normalize();
    await _save();
    notifyListeners();
    final paid = server.payment;
    if (paid != null) await _applyOutcome(a.id, paid);
  }

  /// If a payment was left unfinished, ask the backend what really happened.
  Future<void> reconcilePayment() async {
    if (paymentBusy) return;
    if (!payments.isConfigured && !backend.isConnected) return;
    Commitment? open;
    for (final c in _items.reversed) {
      if (c.payment?.needsFollowUp == true) {
        open = c;
        break;
      }
    }
    if (open == null) return;
    paymentBusy = true;
    try {
      await _applyOutcome(open.id, await _status(open.id));
    } finally {
      paymentBusy = false;
      notifyListeners();
    }
  }

  /// The backend's authoritative payment status for a challenge.
  Future<PaymentOutcome> _status(String challengeId) async {
    try {
      return await backend.paymentStatus(challengeId);
    } catch (_) {
      return const PaymentOutcome(PaymentStatus.networkError);
    }
  }

  /// Stores the outcome on the challenge; ends the challenge only on a
  /// success confirmed by the backend.
  Future<PaymentOutcome> _applyOutcome(String id, PaymentOutcome o) async {
    final c = byId(id);
    if (c == null) return o;
    final now = clock.now();
    final base =
        c.payment ??
        PaymentRecord(
          reference: '',
          amountRupees: c.commitmentAmount,
          status: PaymentStatus.notStarted,
          initiatedAt: now,
        );
    final success = o.status == PaymentStatus.successful;
    final record = base.copyWith(
      status: o.status,
      transactionId: o.transactionId,
      paidAt: success ? (o.paidAt ?? now) : null,
      updatedAt: now,
      authoritative: backend.isConnected,
      refund: o.refund,
      refundedAt: o.refundedAt,
    );

    if (success) {
      if (c.isLive) {
        _replace(CommitmentEngine.endEarly(c, record, now));
      } else {
        // The challenge finished by itself while the payment was in flight.
        // The verified payment stays on record and is never charged again.
        _replace(c.copyWith(payment: record));
      }
      relockNotice = false;
      await _save();
      notifyListeners();
      return o;
    }
    _replace(c.copyWith(payment: record));
    await _save();
    notifyListeners();
    return o;
  }

  /// Lets payment apps through the blocker while a checkout is open.
  Future<void> _openCheckoutWindow(int attempt) async {
    if (attempt > maxCheckoutWindows) return;
    checkoutUntil = clock.now().add(checkoutWindow);
    await _save();
  }

  Future<void> _closeCheckoutWindow() async {
    if (checkoutUntil == null) return;
    checkoutUntil = null;
    await _save();
  }

  Future<void> _setPayment(String id, PaymentRecord record) async {
    final c = byId(id);
    if (c == null) return;
    _replace(c.copyWith(payment: record));
    await _save();
  }

  Future<void> acknowledgeCompletion(String id) async {
    final c = byId(id);
    if (c == null || c.completionAcknowledged) return;
    _replace(c.copyWith(completionAcknowledged: true));
    await _save();
    notifyListeners();
  }

  void dismissRelockNotice() {
    if (!relockNotice) return;
    relockNotice = false;
    notifyListeners();
  }

  void clearLoadWarning() => loadWarning = null;

  /// Deletes history. A running commitment is deliberately kept, so that
  /// "Reset" cannot be used as an unlock button.
  Future<void> resetData() async {
    if (_normalize()) await _save();
    // Keeps the running challenge and every record where money moved or may
    // still move. This is a local clean-up only: the backend's payment
    // history is the authoritative one and is not touched by it.
    _items = _items
        .where((c) => c.isLive || (c.payment?.mustBeKept ?? false))
        .toList();
    await _save();
    notifyListeners();
  }

  // -------------------------------------------------------------- internals

  Future<void> _syncClock() async {
    final c = clock;
    if (c is SyncedClock) await c.sync();
  }

  void _replace(Commitment c) {
    final i = _items.indexWhere((x) => x.id == c.id);
    if (i >= 0) _items[i] = c;
  }

  /// Applies time-based transitions. Returns true if anything changed.
  bool _normalize() {
    final now = clock.now();
    var changed = false;
    for (var i = 0; i < _items.length; i++) {
      final before = _items[i];
      final after = CommitmentEngine.resolve(before, now);
      if (identical(before, after)) continue;
      if (before.status == CommitmentStatus.emergency &&
          after.status == CommitmentStatus.active) {
        relockNotice = true;
      }
      if (after.status == CommitmentStatus.completed) {
        relockNotice = false;
        _queueEvent(after, ChallengeEvent.completedOnDevice, after.endTime);
      }
      _items[i] = after;
      changed = true;
    }
    return changed;
  }

  Future<void> _save() => bridge.saveState(
    jsonEncode({
      'version': _schemaVersion,
      'onboarded': onboarded,
      'accessibilityConsent': accessibilityConsent,
      'installId': installId,
      'checkout': checkoutUntil == null
          ? null
          : {'until': checkoutUntil!.millisecondsSinceEpoch},
      'pendingRegistration': pendingRegistration?.toJson(),
      'outbox': [for (final e in outbox) e.toJson()],
      'commitments': [for (final c in _items) c.toJson()],
    }),
  );
}
