import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/transaction.dart';
import '../models/user.dart';
import 'api_service.dart';
import 'local_database.dart';
import 'signature_service.dart';
import '../utils/balance.dart';

/// Phase 6: synchronization between the offline SQLite ledger and the
/// backend. The offline flow NEVER calls this - it only runs when the
/// user taps Sync (or a future auto-sync trigger fires).
///
/// The contract (see backend/src/controllers/syncController.js):
///
///   PUSH - upload every PENDING_SYNC transaction; the server verifies
///          signatures (Phase 5), stores each payment once, refuses
///          replays, and answers with a per-transaction outcome that we
///          apply to the local ledger.
///
///   PULL - download everything the server knows about us: payments the
///          OTHER device uploaded while we were offline, plus statuses.
///
/// Balance bookkeeping is the subtle part: `profile.balance` is the
/// CONFIRMED money (what the server agrees with) and unsettled outgoing
/// payments are subtracted from it on the fly (see utils/balance.dart):
///
///   server confirms OUR outgoing payment -> balance -= amount
///     (the money really left the account)
///   server confirms an incoming payment  -> balance += amount
///     (the money really arrived - even if we were offline when it did)
///   server rejects / conflicts          -> status changes only; the
///     transaction stops being "unsettled", which RELEASES its local
///     reservation (the money becomes spendable again, because the
///     server refused to spend it)
///
/// Transport failures are NOT errors of the queue: if push or pull
/// throws, nothing is modified, transactions stay PENDING_SYNC, and the
/// report explains what happened. That is the offline-first contract -
/// syncing can fail any number of times without losing a payment.
class SyncService {
  SyncService({
    required LocalDatabase db,
    required SyncTransport transport,
  })  : _db = db,
        _transport = transport;

  final LocalDatabase _db;
  final SyncTransport _transport;

  /// Run one full sync cycle for [userId].
  ///
  /// [publicKey] is this device's Ed25519 key when one exists - declaring
  /// it lets the server bind the key to the user on their first push
  /// (trust-on-first-use; see OFFLINE_FIRST.md section 8 for what that
  /// does and does not prove).
  Future<SyncReport> syncNow({
    required String userId,
    String? publicKey,
  }) async {
    final report = SyncReport();

    // 1. PUSH: upload the queue, apply the server's verdicts.
    try {
      final pending = await _db.getPendingSyncTransactions();
      if (pending.isNotEmpty) {
        final push = await _transport.push(
          userId: userId,
          publicKey: publicKey,
          transactions: pending,
        );
        report.pushed = pending.length;
        for (final outcome in push.outcomes) {
          await _applyOutcome(outcome, userId, report);
        }
      }
    } catch (error) {
      // Queue untouched - still PENDING_SYNC, nothing lost.
      report.errorMessage = 'Push failed: $error';
    }

    // 2. PULL: merge what the server knows.
    try {
      final pull = await _transport.pull(userId: userId);
      for (final tx in pull.transactions) {
        await _mergePulled(tx, userId, report);
      }
    } catch (error) {
      final pullError = 'Pull failed: $error';
      report.errorMessage =
          report.errorMessage == null ? pullError : '${report.errorMessage} | $pullError';
    }

    return report;
  }

  /// Apply one server verdict to the matching local transaction.
  Future<void> _applyOutcome(
    SyncOutcome outcome,
    String userId,
    SyncReport report,
  ) async {
    switch (outcome.outcomeType) {
      case SyncOutcomeType.confirmed:
        report.confirmed++;
        await _settleLocal(
          outcome.transactionId,
          TransactionStatus.confirmed,
          userId,
          bookBalance: true,
        );
      case SyncOutcomeType.duplicate:
        // DUPLICATE = "the server already has this exact copy" - e.g. our
        // previous push succeeded but the response was lost in transit.
        // Either way the money moved server-side: book it exactly once
        // (the unsettled guard inside _settleLocal prevents a second
        // adjustment on any later sync).
        report.duplicates++;
        await _settleLocal(
          outcome.transactionId,
          TransactionStatus.confirmed,
          userId,
          bookBalance: true,
        );
      case SyncOutcomeType.conflict:
        report.conflicts++;
        await _settleLocal(
          outcome.transactionId,
          TransactionStatus.conflict,
          userId,
          reason: outcome.reason ?? 'conflict reported by server',
        );
      case SyncOutcomeType.rejected:
      case SyncOutcomeType.unknown:
        report.rejected++;
        await _settleLocal(
          outcome.transactionId,
          TransactionStatus.rejected,
          userId,
          reason: outcome.reason ?? 'rejected by server',
        );
    }
  }

  /// Transition one local transaction to a settled status.
  ///
  /// Only an UNSETTLED -> confirmed transition moves the confirmed
  /// balance, so re-syncing (or a lost response followed by a retry)
  /// can never double-book the same payment.
  Future<void> _settleLocal(
    String transactionId,
    TransactionStatus status,
    String userId, {
    bool bookBalance = false,
    String? reason,
  }) async {
    final tx = await _db.getTransactionById(transactionId);
    if (tx == null) return; // server answered about something we lack - ignore

    final wasUnsettled = isUnsettled(tx.status);
    await _db.updateTransactionStatus(transactionId, status,
        rejectionReason: reason);

    if (bookBalance && wasUnsettled) {
      await _adjustConfirmedBalance(tx, userId);
    }
  }

  /// Merge one transaction returned by the pull into the local ledger.
  Future<void> _mergePulled(
    Transaction tx,
    String userId,
    SyncReport report,
  ) async {
    // Only transactions that actually involve this wallet.
    if (tx.senderId != userId && tx.receiverId != userId) {
      report.skippedForeign++;
      return;
    }

    // Defense in depth: verify the signature ourselves even though the
    // server already did. Transports lie (and this one is cleartext
    // HTTP) - a tampered pull must never enter the ledger. Unsigned
    // legacy transactions are accepted, consistent with the QR path.
    if (tx.signature != null || tx.senderPublicKey != null) {
      final valid = tx.signature != null &&
          tx.senderPublicKey != null &&
          await SignatureService.verify(
            SignatureService.canonicalPayload(tx),
            signatureBase64: tx.signature!,
            publicKeyBase64: tx.senderPublicKey!,
          );
      if (!valid) {
        report.skippedTampered++;
        return;
      }
    }

    final existing = await _db.getTransactionById(tx.transactionId);

    if (existing == null) {
      // New to us - e.g. the payer uploaded this payment while we were
      // offline. Store it with the SERVER's status (the authority), and
      // let confirmed money move the balance.
      final inserted = await _db.insertTransaction(tx);
      if (inserted) {
        report.pulledNew++;
        if (tx.status == TransactionStatus.confirmed) {
          await _adjustConfirmedBalance(tx, userId);
        }
      } else {
        report.skippedForeign++; // raced with ourselves; treat as no-op
      }
      return;
    }

    // We already have it. Advance it only if the local copy is still
    // unsettled and the server is further along - never regress a status
    // the server itself confirmed earlier.
    if (isUnsettled(existing.status) && tx.status != existing.status) {
      await _db.updateTransactionStatus(
        existing.transactionId,
        tx.status,
        rejectionReason: tx.rejectionReason,
      );
      report.pulledUpdated++;
      if (tx.status == TransactionStatus.confirmed) {
        await _adjustConfirmedBalance(existing, userId);
      }
    }
  }

  /// Move the CONFIRMED balance (wallet_profile.balance) to reflect a
  /// payment the server just confirmed. Outgoing debits, incoming credits
  /// - the same ledger movement the server made on its side.
  Future<void> _adjustConfirmedBalance(Transaction tx, String userId) async {
    final User? profile = await _db.getWalletProfile();
    if (profile == null) return;
    final delta = tx.senderId == userId ? -tx.amount : tx.amount;
    await _db.updateConfirmedBalance(userId, profile.balance + delta);
  }
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

/// The wire interface between [SyncService] and the outside world.
///
/// Tests inject a fake (no network under `flutter test`); production uses
/// [HttpSyncTransport].
abstract class SyncTransport {
  Future<PushResult> push({
    required String userId,
    String? publicKey,
    required List<Transaction> transactions,
  });

  Future<PullResult> pull({required String userId});
}

/// Production transport: plain REST over HTTP against the backend.
///
/// HONEST NOTE: this is cleartext HTTP on purpose (a college prototype on
/// a LAN). A real deployment needs TLS; transaction signatures protect
/// content integrity in transit, but not privacy or server identity.
class HttpSyncTransport implements SyncTransport {
  const HttpSyncTransport();

  /// Syncs must not hang the UI forever - especially when "offline"
  /// actually means "no route to host".
  static const Duration _timeout = Duration(seconds: 10);

  @override
  Future<PushResult> push({
    required String userId,
    String? publicKey,
    required List<Transaction> transactions,
  }) async {
    final response = await http
        .post(
          Uri.parse('${ApiService.baseUrl}/sync/push'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'userId': userId,
            'publicKey': publicKey,
            'transactions': transactions.map((t) => t.toJson()).toList(),
          }),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('sync push failed (HTTP ${response.statusCode})');
    }
    final data = jsonDecode(response.body)['data'] as Map<String, dynamic>;
    return PushResult(
      registration: data['registration'] as String? ?? 'unknown',
      outcomes: (data['results'] as List)
          .map((r) => SyncOutcome.fromJson(r as Map<String, dynamic>))
          .toList(),
    );
  }

  @override
  Future<PullResult> pull({required String userId}) async {
    final response = await http
        .post(
          Uri.parse('${ApiService.baseUrl}/sync/pull'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'userId': userId}),
        )
        .timeout(_timeout);

    if (response.statusCode != 200) {
      throw Exception('sync pull failed (HTTP ${response.statusCode})');
    }
    final data = jsonDecode(response.body)['data'] as Map<String, dynamic>;
    return PullResult(
      transactions: (data['transactions'] as List)
          .map((j) => Transaction.fromJson(j as Map<String, dynamic>))
          .toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Result models
// ---------------------------------------------------------------------------

enum SyncOutcomeType { confirmed, duplicate, conflict, rejected, unknown }

class SyncOutcome {
  const SyncOutcome({
    required this.transactionId,
    required this.outcomeType,
    this.serverStatus,
    this.reason,
  });

  factory SyncOutcome.fromJson(Map<String, dynamic> json) {
    return SyncOutcome(
      transactionId: json['transactionId'] as String? ?? '',
      outcomeType: switch (json['outcome'] as String?) {
        'CONFIRMED' => SyncOutcomeType.confirmed,
        'DUPLICATE' => SyncOutcomeType.duplicate,
        'CONFLICT' => SyncOutcomeType.conflict,
        'REJECTED' => SyncOutcomeType.rejected,
        _ => SyncOutcomeType.unknown,
      },
      serverStatus: json['serverStatus'] as String?,
      reason: json['reason'] as String?,
    );
  }

  final String transactionId;
  final SyncOutcomeType outcomeType;
  final String? serverStatus;
  final String? reason;
}

class PushResult {
  const PushResult({required this.registration, required this.outcomes});

  /// Key registration verdict ('bound', 'already-bound', ...).
  final String registration;
  final List<SyncOutcome> outcomes;
}

class PullResult {
  const PullResult({required this.transactions});

  final List<Transaction> transactions;
}

/// What one sync cycle achieved - shown to the user and asserted in tests.
class SyncReport {
  int pushed = 0;
  int confirmed = 0;
  int duplicates = 0;
  int conflicts = 0;
  int rejected = 0;
  int pulledNew = 0;
  int pulledUpdated = 0;
  int skippedTampered = 0;
  int skippedForeign = 0;
  String? errorMessage;

  bool get ok => errorMessage == null;

  /// One-line human summary for the Home screen.
  String get summary {
    if (errorMessage != null) return errorMessage!;
    final parts = <String>[
      if (confirmed > 0) '$confirmed confirmed',
      if (duplicates > 0) '$duplicates already known',
      if (rejected > 0) '$rejected rejected',
      if (conflicts > 0) '$conflicts conflicted',
      if (pulledNew > 0) '$pulledNew received',
      if (pulledUpdated > 0) '$pulledUpdated updated',
      if (skippedTampered > 0) '$skippedTampered tampered (skipped)',
    ];
    return parts.isEmpty ? 'Already up to date' : parts.join(', ');
  }
}
