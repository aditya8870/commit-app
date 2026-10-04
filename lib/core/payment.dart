/// Every state a payment for ending a challenge early can be in.
enum PaymentStatus {
  notStarted('NOT_STARTED'),
  initiated('INITIATED'),
  pending('PENDING'),
  successful('SUCCESSFUL'),
  failed('FAILED'),
  cancelled('CANCELLED'),
  verificationFailed('VERIFICATION_FAILED'),
  networkError('NETWORK_ERROR');

  const PaymentStatus(this.wire);
  final String wire;

  static PaymentStatus parse(Object? value) => values.firstWhere(
    (s) => s.wire == value,
    orElse: () => throw FormatException('Unknown payment status: $value'),
  );

  /// Money may have moved (or may still move) for this reference, so the
  /// next step must be to ask the provider again, never to charge again.
  bool get mustVerifyBeforeRetry =>
      this == initiated ||
      this == pending ||
      this == verificationFailed ||
      this == networkError;
}

/// Whether money that was taken is on its way back. Decided by the backend.
enum RefundStatus {
  none('NONE'),
  pending('REFUND_PENDING'),
  refunded('REFUNDED'),
  failed('REFUND_FAILED');

  const RefundStatus(this.wire);
  final String wire;

  static RefundStatus parse(Object? value) =>
      values.firstWhere((s) => s.wire == value, orElse: () => none);
}

/// What is sent to the payment provider. One challenge has exactly one
/// [reference], so repeating a request can never create a second charge.
class PaymentRequest {
  const PaymentRequest({
    required this.reference,
    required this.challengeId,
    required this.amountRupees,
    required this.description,
  });
  final String reference;
  final String challengeId;
  final int amountRupees;
  final String description;
}

/// What the provider (or the backend that verifies it) answered.
class PaymentOutcome {
  const PaymentOutcome(
    this.status, {
    this.transactionId,
    this.paidAt,
    this.message,
    this.refund = RefundStatus.none,
    this.refundedAt,
  });

  /// Set by the backend when a payment is being, or has been, returned.
  final RefundStatus refund;
  final DateTime? refundedAt;
  final PaymentStatus status;
  final String? transactionId;
  final DateTime? paidAt;

  /// Short explanation that can be shown to the user.
  final String? message;
}

/// The seam where a real payment provider plugs in.
///
/// Rules an implementation must follow:
///  * [pay] opens the provider's own secure checkout. The app never sees or
///    stores card numbers, CVV, UPI PIN or banking passwords.
///  * [pay] is idempotent per [PaymentRequest.reference].
///  * [verify] asks the BACKEND (which checks the provider's signature or
///    webhook) for the true state of a reference. A "success" reported by the
///    client-side checkout alone is never proof of payment; the controller
///    only ends a challenge after [verify] returns successful.
abstract class PaymentService {
  /// False when no provider is connected; the UI then says so plainly.
  bool get isConfigured;

  Future<PaymentOutcome> pay(PaymentRequest request);

  Future<PaymentOutcome> verify(String reference);
}

/// Used until a real provider is connected. It never reports success, so a
/// challenge can never be ended early (and nobody can be charged) with it.
class UnconfiguredPaymentService implements PaymentService {
  const UnconfiguredPaymentService();

  static const message =
      'Payments are not connected in this version. Nothing was charged.';

  @override
  bool get isConfigured => false;

  @override
  Future<PaymentOutcome> pay(PaymentRequest request) async =>
      const PaymentOutcome(PaymentStatus.failed, message: message);

  @override
  Future<PaymentOutcome> verify(String reference) async =>
      const PaymentOutcome(PaymentStatus.notStarted, message: message);
}

/// The payment facts kept with a challenge. Contains no payment credentials.
///
/// This is the phone's COPY. The backend's record is the authoritative one;
/// [authoritative] says whether the status here was confirmed by a real
/// server or only by the local stand-in.
class PaymentRecord {
  const PaymentRecord({
    required this.reference,
    required this.amountRupees,
    required this.status,
    required this.initiatedAt,
    this.transactionId,
    this.paidAt,
    this.updatedAt,
    this.idempotencyKey,
    this.attempt = 0,
    this.expiresAt,
    this.authoritative = false,
    this.refund = RefundStatus.none,
    this.refundedAt,
  });

  /// Issued by the backend when it authorises an attempt. Empty until then.
  final String reference;

  /// The amount the backend authorised for this payment.
  final int amountRupees;
  final PaymentStatus status;
  final DateTime initiatedAt;
  final String? transactionId;
  final DateTime? paidAt;

  /// When the status was last confirmed or changed.
  final DateTime? updatedAt;

  /// Key of the current attempt's authorisation request, saved before the
  /// request is sent so a crash and retry reuses it.
  final String? idempotencyKey;

  /// How many checkouts the backend has authorised for this challenge.
  final int attempt;

  /// After this time the backend will not accept this attempt.
  final DateTime? expiresAt;

  /// True when [status] came from a connected backend.
  final bool authoritative;

  /// Refund state as last reported by the backend.
  final RefundStatus refund;
  final DateTime? refundedAt;

  /// Money is involved or may be: this record must survive a local reset.
  bool get mustBeKept =>
      status == PaymentStatus.successful ||
      status.mustVerifyBeforeRetry ||
      refund != RefundStatus.none;

  /// The backend should be asked again: the outcome is unknown, or a refund
  /// is still on its way.
  bool get needsFollowUp =>
      status.mustVerifyBeforeRetry || refund == RefundStatus.pending;

  /// The backend will no longer accept this attempt.
  bool isExpired(DateTime now) {
    final e = expiresAt;
    return e != null && !now.isBefore(e);
  }

  PaymentRecord copyWith({
    String? reference,
    int? amountRupees,
    PaymentStatus? status,
    String? transactionId,
    DateTime? paidAt,
    DateTime? updatedAt,
    String? idempotencyKey,
    int? attempt,
    DateTime? expiresAt,
    bool? authoritative,
    RefundStatus? refund,
    DateTime? refundedAt,
  }) => PaymentRecord(
    initiatedAt: initiatedAt,
    reference: reference ?? this.reference,
    amountRupees: amountRupees ?? this.amountRupees,
    status: status ?? this.status,
    transactionId: transactionId ?? this.transactionId,
    paidAt: paidAt ?? this.paidAt,
    updatedAt: updatedAt ?? this.updatedAt,
    idempotencyKey: idempotencyKey ?? this.idempotencyKey,
    attempt: attempt ?? this.attempt,
    expiresAt: expiresAt ?? this.expiresAt,
    authoritative: authoritative ?? this.authoritative,
    refund: refund ?? this.refund,
    refundedAt: refundedAt ?? this.refundedAt,
  );

  Map<String, Object?> toJson() => {
    'reference': reference,
    'amountRupees': amountRupees,
    'status': status.wire,
    'initiatedAt': initiatedAt.millisecondsSinceEpoch,
    'transactionId': transactionId,
    'paidAt': paidAt?.millisecondsSinceEpoch,
    'updatedAt': updatedAt?.millisecondsSinceEpoch,
    'idempotencyKey': idempotencyKey,
    'attempt': attempt,
    'expiresAt': expiresAt?.millisecondsSinceEpoch,
    'authoritative': authoritative,
    'refund': refund.wire,
    'refundedAt': refundedAt?.millisecondsSinceEpoch,
  };

  factory PaymentRecord.fromJson(Map<String, Object?> j) {
    DateTime? time(String k) =>
        j[k] is int ? DateTime.fromMillisecondsSinceEpoch(j[k] as int) : null;
    final ref = j['reference'], amount = j['amountRupees'];
    final started = time('initiatedAt');
    if (ref is! String || amount is! int || started == null) {
      throw const FormatException('Invalid payment record');
    }
    return PaymentRecord(
      reference: ref,
      amountRupees: amount,
      status: PaymentStatus.parse(j['status']),
      initiatedAt: started,
      transactionId: j['transactionId'] as String?,
      paidAt: time('paidAt'),
      updatedAt: time('updatedAt'),
      idempotencyKey: j['idempotencyKey'] as String?,
      attempt: j['attempt'] is int ? j['attempt'] as int : 0,
      expiresAt: time('expiresAt'),
      authoritative: j['authoritative'] == true,
      refund: RefundStatus.parse(j['refund']),
      refundedAt: time('refundedAt'),
    );
  }
}
