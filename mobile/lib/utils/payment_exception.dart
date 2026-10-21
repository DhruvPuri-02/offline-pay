/// Thrown when an offline payment cannot be created.
///
/// [reason] is written for the end user and is shown verbatim in the UI
/// (spec section 13: every rejection must carry a clear reason).
class PaymentException implements Exception {
  const PaymentException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}
