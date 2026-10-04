/// Commit has no accounts. An install of the app is identified by a
/// server-issued ID and a secret credential that only this phone knows.
library;

/// The two values that identify this install to the server.
class InstallationIdentity {
  const InstallationIdentity({required this.id, required this.credential});

  /// Issued by the server. Not secret.
  final String id;

  /// 256 random bits made on this phone. Secret: it is kept in encrypted
  /// storage, sent only in an HTTPS header, and never logged or shown.
  final String credential;

  static final _credentialFormat = RegExp(r'^[A-Za-z0-9_-]{43}$');
  static final _idFormat = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  static bool isCredential(Object? v) =>
      v is String && _credentialFormat.hasMatch(v);
  static bool isId(Object? v) => v is String && _idFormat.hasMatch(v);

  /// Deliberately leaves the credential out, so printing this by accident
  /// cannot leak it.
  @override
  String toString() => 'InstallationIdentity($id)';
}

enum InstallationStatus {
  /// Not checked yet, or encrypted storage could not be read.
  unknown,

  /// No installation is stored on this phone yet.
  unregistered,

  /// An installation ID and credential are stored on this phone.
  registered,
}

/// A failed API call. Carries a code and nothing sensitive: never a request
/// body, a header or a credential.
class ApiException implements Exception {
  const ApiException(
    this.code, {
    this.status,
    this.retryable = false,
    this.retryAfter,
    this.details = const {},
  });

  // Codes made on the phone. Everything else comes from the server.
  static const network = 'NETWORK';
  static const timeout = 'TIMEOUT';
  static const malformedResponse = 'MALFORMED_RESPONSE';

  // Server codes the app reacts to.
  static const unauthenticated = 'UNAUTHENTICATED';
  static const recoveryRequired = 'RECOVERY_REQUIRED';
  static const recoveryNotFound = 'RECOVERY_NOT_FOUND';
  static const credentialInUse = 'CREDENTIAL_IN_USE';
  static const rateLimited = 'RATE_LIMITED';
  static const notFound = 'NOT_FOUND';
  static const paymentsUnavailable = 'PAYMENTS_UNAVAILABLE';
  static const tooEarly = 'TOO_EARLY';
  static const challengeNotActive = 'CHALLENGE_NOT_ACTIVE';
  static const emergencyLimitExceeded = 'EMERGENCY_LIMIT_EXCEEDED';
  static const validationFailed = 'VALIDATION_FAILED';

  final String code;
  final int? status;

  /// True when trying again later may work.
  final bool retryable;

  /// How long the server asked us to wait, if it said.
  final Duration? retryAfter;

  /// The rest of the server's error answer (for example the seconds
  /// remaining). The server never puts a secret in an answer.
  final Map<String, Object?> details;

  @override
  String toString() =>
      'ApiException($code${status == null ? '' : ', $status'})';
}
