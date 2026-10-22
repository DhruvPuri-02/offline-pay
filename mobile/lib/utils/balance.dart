import '../models/transaction.dart';

/// Pure, side-effect-free wallet maths.
///
/// This file deliberately has NO dependencies on Flutter, SQLite or HTTP so
/// the double-spend rules can be unit-tested in milliseconds.
///
/// Three balances are kept apart on purpose (see project spec section 10):
///
///   confirmed   - what the backend has agreed with us
///   pending     - offline payments made/received but not yet synchronized
///   available   - what you may spend RIGHT NOW while offline
///
/// The critical decision: **incoming pending money does NOT increase
/// available balance.** Until the backend reconciles, we cannot know whether
/// a payment we received offline will survive conflict resolution (the
/// sender might have spent the same money elsewhere while offline). Counting
/// it would let users double-spend unconfirmed receipts. This is deliberately
/// conservative.
class BalanceSummary {
  const BalanceSummary({
    required this.confirmed,
    required this.pendingOutgoing,
    required this.pendingIncoming,
    required this.available,
  });

  final double confirmed;
  final double pendingOutgoing;
  final double pendingIncoming;
  final double available;

  /// Offline / pending exposure: money that has moved locally but is not
  /// yet settled with the backend.
  double get pendingNet => pendingIncoming - pendingOutgoing;
}

const List<TransactionStatus> _unsettledStatuses = [
  TransactionStatus.pendingSync,
  TransactionStatus.syncing,
];

/// A transaction that has locally moved but is not settled with the
/// backend yet - it reserves money (outgoing) or claims money (incoming)
/// until the server's verdict arrives. Used by the balance maths AND by
/// Phase 6 sync, which only applies server verdicts to unsettled rows.
bool isUnsettled(TransactionStatus status) => _unsettledStatuses.contains(status);

/// Compute all three balances from the confirmed balance + the local ledger.
BalanceSummary computeBalance({
  required double confirmed,
  required List<Transaction> transactions,
  required String userId,
}) {
  double outgoing = 0;
  double incoming = 0;

  for (final tx in transactions) {
    if (!isUnsettled(tx.status)) continue;
    if (tx.senderId == userId) {
      outgoing += tx.amount;
    } else if (tx.receiverId == userId) {
      incoming += tx.amount;
    }
  }

  final available = confirmed - outgoing;

  return BalanceSummary(
    confirmed: confirmed,
    pendingOutgoing: outgoing,
    pendingIncoming: incoming,
    // Never display a negative number: the ledger is the evidence, the
    // UI shows 0 if something inconsistent slips through.
    available: available < 0 ? 0 : available,
  );
}

/// Result of checking whether an offline payment may be created.
class SpendDecision {
  const SpendDecision.allowed()
      : allowed = true,
        reason = null;

  const SpendDecision.denied(this.reason)
      : allowed = false;

  final bool allowed;

  /// User-facing explanation when [allowed] is false, e.g.
  /// "Insufficient available offline balance (₹100 available, ₹400 requested)."
  final String? reason;
}

/// The offline spending rules (a practical first cut at double-spend
/// prevention - see docs/ for the honest limitations).
///
/// Every rule here is LOCAL and therefore only as trustworthy as the device
/// it runs on. The backend re-checks all of this during Phase 6 sync; that
/// second check is what actually prevents double-spending across time.
SpendDecision validateOfflinePayment({
  required double amount,
  required double available,
  required String senderId,
  required String receiverId,
  required double maxOfflineAmount,
}) {
  if (senderId.isEmpty || receiverId.isEmpty) {
    return const SpendDecision.denied('Sender and receiver are required.');
  }
  if (senderId == receiverId) {
    return const SpendDecision.denied('Cannot pay yourself.');
  }
  if (amount <= 0) {
    return const SpendDecision.denied('Amount must be greater than 0.');
  }

  // Rule 1: per-transaction offline cap. Keeps a single compromised device
  // from writing an arbitrarily large "offline" payment into its ledger.
  if (amount > maxOfflineAmount) {
    return SpendDecision.denied(
      'Offline payments are limited to ₹${maxOfflineAmount.toStringAsFixed(0)} '
      'per transaction (requested ₹${amount.toStringAsFixed(2)}).',
    );
  }

  // Rule 2: local balance reservation. `available` already has every
  // unsettled outgoing payment subtracted, so paying ₹400 of a ₹500
  // balance leaves ₹100 - and a second ₹400 payment is refused here.
  if (amount > available) {
    return SpendDecision.denied(
      'Insufficient available offline balance '
      '(₹${available.toStringAsFixed(2)} available, '
      '₹${amount.toStringAsFixed(2)} requested).',
    );
  }

  return const SpendDecision.allowed();
}
