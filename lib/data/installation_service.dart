import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/installation.dart';
import '../platform/installation_platform.dart';
import 'api_client.dart';

/// Registers this install with the server and keeps its identity.
///
/// Runs in the background. Nothing in the app waits for it, and blocking,
/// challenges, countdowns and emergency access do not depend on it: with no
/// network the app behaves exactly as before.
///
/// It never logs, and no error it produces contains a credential.
class InstallationService {
  InstallationService({
    required this.platform,
    required this.api,
    Random? random,
    DateTime Function()? now,
    this.retryDelay = const Duration(seconds: 60),
    this.longRetryDelay = const Duration(minutes: 15),
  }) : _random = random ?? Random.secure(),
       _now = now ?? DateTime.now;

  // Names in encrypted storage.
  static const kId = 'installation_id';
  static const kCredential = 'installation_credential';

  /// A credential that has been generated but not yet confirmed by the
  /// server. Saved BEFORE the request, so if the app dies in between, the
  /// same credential is sent again and the server answers with the same
  /// installation instead of creating a second one.
  static const kPending = 'pending_credential';

  static final _materialFormat = RegExp(r'^[0-9a-f]{64}$');

  final InstallationPlatform platform;
  final ApiClient api;
  final Random _random;
  final DateTime Function() _now;
  final Duration retryDelay;
  final Duration longRetryDelay;

  InstallationIdentity? _identity;
  InstallationStatus status = InstallationStatus.unknown;

  /// Code of the last failure, for diagnostics. Never contains a secret.
  String? lastErrorCode;

  DateTime? _nextAttempt;
  bool _verified = false;
  Future<InstallationStatus>? _inFlight;
  Future<void>? _starting;

  /// The stored identity, once known. Used by later phases to sign requests.
  InstallationIdentity? get identity => _identity;

  /// Called at app start and whenever the app comes to the front. Safe to
  /// call any number of times; never throws.
  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    try {
      final s = await ensureRegistered();
      if (s == InstallationStatus.registered && !_verified) await verify();
    } catch (_) {
      // Identity is best-effort in this phase; the app carries on.
    }
  }

  /// The identity stored on this phone, without using the network. Null if
  /// this phone is not registered yet or encrypted storage cannot be read.
  Future<InstallationIdentity?> loadStored() async {
    if (_identity != null) return _identity;
    try {
      final id = await platform.secureRead(kId);
      final credential = await platform.secureRead(kCredential);
      if (InstallationIdentity.isId(id) &&
          InstallationIdentity.isCredential(credential)) {
        status = InstallationStatus.registered;
        return _identity = InstallationIdentity(
          id: id!,
          credential: credential!,
        );
      }
    } catch (_) {}
    return null;
  }

  /// Makes sure this phone has an installation. Does nothing over the network
  /// if one is already stored. Concurrent calls share one attempt.
  Future<InstallationStatus> ensureRegistered({bool force = false}) =>
      _inFlight ??= _ensure(force).whenComplete(() => _inFlight = null);

  Future<InstallationStatus> _ensure(bool force) async {
    if (_identity != null) return status = InstallationStatus.registered;

    final String? id, credential;
    try {
      id = await platform.secureRead(kId);
      credential = await platform.secureRead(kCredential);
    } catch (_) {
      // Encrypted storage is unavailable. Do nothing rather than risk
      // creating a second installation.
      lastErrorCode = 'STORAGE';
      return status = InstallationStatus.unknown;
    }
    if (InstallationIdentity.isId(id) &&
        InstallationIdentity.isCredential(credential)) {
      _identity = InstallationIdentity(id: id!, credential: credential!);
      return status = InstallationStatus.registered;
    }

    status = InstallationStatus.unregistered;
    final wait = _nextAttempt;
    if (!force && wait != null && _now().isBefore(wait)) return status;

    try {
      await _register();
      lastErrorCode = null;
      _nextAttempt = null;
      return status = InstallationStatus.registered;
    } on ApiException catch (e) {
      lastErrorCode = e.code;
      if (e.code == ApiException.credentialInUse) {
        // Astronomically unlikely; start again with a fresh credential.
        await _safeDelete(kPending);
      }
      _nextAttempt = _now().add(
        e.retryAfter ?? (e.retryable ? retryDelay : longRetryDelay),
      );
    } catch (_) {
      lastErrorCode = 'STORAGE';
      _nextAttempt = _now().add(retryDelay);
    }
    return status;
  }

  Future<void> _register() async {
    var pending = await platform.secureRead(kPending);
    if (!InstallationIdentity.isCredential(pending)) {
      pending = _newCredential();
      await platform.secureWrite(kPending, pending);
    }
    final body = <String, Object?>{
      'credential': pending,
      'recoveryMaterial': await _recoveryMaterial(),
      'appVersion': await _version(),
      'androidVersion': await _androidVersion(),
    };

    Map<String, Object?> answer;
    try {
      answer = await api.send('POST', '/v1/installations', body: body);
    } on ApiException catch (e) {
      if (e.code != ApiException.recoveryRequired) rethrow;
      // This phone already has an installation (a reinstall): take it over
      // with the new credential instead of creating a second one.
      answer = await api.send('POST', '/v1/installations/recover', body: body);
    }

    final id = answer['installationId'];
    if (!InstallationIdentity.isId(id)) {
      throw const ApiException(ApiException.malformedResponse);
    }
    // Credential first: an ID without its credential is useless, and a
    // credential without an ID is repaired by the next (idempotent) attempt.
    await platform.secureWrite(kCredential, pending!);
    await platform.secureWrite(kId, id as String);
    await _safeDelete(kPending);
    _identity = InstallationIdentity(id: id, credential: pending);
  }

  /// Checks with the server that the stored identity still works, and keeps
  /// reinstall recovery up to date. Returns true if the server accepted it.
  /// Never throws.
  Future<bool> verify() async {
    final me = _identity;
    if (me == null) return false;
    try {
      final answer = await api.send('GET', '/v1/installations/me', auth: me);
      _verified = true;
      lastErrorCode = null;
      if (answer['recoveryUpToDate'] == false) await _refreshRecovery(me);
      return true;
    } on ApiException catch (e) {
      lastErrorCode = e.code;
      if (e.code == ApiException.unauthenticated) await _onRejected();
      return false;
    } catch (_) {
      return false;
    }
  }

  /// The server no longer accepts the stored credential (it was replaced by
  /// a recovery elsewhere). Only the identity is reset; challenge data on
  /// this phone is not touched. The next attempt recovers the installation.
  Future<void> _onRejected() async {
    _identity = null;
    _verified = false;
    status = InstallationStatus.unregistered;
    await _safeDelete(kCredential);
    await _safeDelete(kId);
    await _safeDelete(kPending);
    _nextAttempt = null;
    await ensureRegistered();
  }

  Future<void> _refreshRecovery(InstallationIdentity me) async {
    final material = await _recoveryMaterial();
    if (material == null) return;
    try {
      await api.send(
        'POST',
        '/v1/installations/me/recovery',
        auth: me,
        body: {'recoveryMaterial': material},
      );
    } on ApiException {
      // Not essential now; tried again next time.
    }
  }

  /// 32 bytes from the system's cryptographic random source, as 43 URL-safe
  /// base64 characters.
  String _newCredential() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<String?> _recoveryMaterial() async {
    try {
      final m = await platform.recoveryMaterial();
      // Anything that is not a 64-character hash is not sent at all.
      return m != null && _materialFormat.hasMatch(m) ? m : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> _version() async {
    try {
      final v = await platform.appVersion();
      return RegExp(r'^[0-9A-Za-z.+_ -]{1,50}$').hasMatch(v) ? v : 'unknown';
    } catch (_) {
      return 'unknown';
    }
  }

  Future<String?> _androidVersion() async {
    try {
      final v = await platform.androidVersion();
      return v != null && RegExp(r'^[0-9A-Za-z.+_ -]{1,50}$').hasMatch(v)
          ? v
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _safeDelete(String name) async {
    try {
      await platform.secureDelete(name);
    } catch (_) {}
  }
}
