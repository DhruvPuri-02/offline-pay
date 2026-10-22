import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/models/transaction.dart';
import 'package:offlinepay/models/user.dart';
import 'package:offlinepay/providers/wallet_provider.dart';
import 'package:offlinepay/services/local_database.dart';
import 'package:offlinepay/services/secure_key_store.dart';
import 'package:offlinepay/services/sync_service.dart';
// hide Transaction: sqflite_common also exports a `Transaction` type.
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

/// Phase 6: what a sync cycle does to the local ledger.
///
/// All tests run against a real in-memory SQLite and a FAKE transport -
/// the server side is exercised for real by backend/scripts/demo-phase6.js
/// (`npm run test:phase5` covers the signature interop those fixtures use).
class FakeSyncTransport implements SyncTransport {
  PushResult? nextPushResult;
  PullResult? nextPullResult;
  bool failPush = false;
  bool failPull = false;

  final List<List<Transaction>> pushedBatches = [];
  String? lastDeclaredPublicKey;

  @override
  Future<PushResult> push({
    required String userId,
    String? publicKey,
    required List<Transaction> transactions,
  }) async {
    pushedBatches.add(transactions);
    lastDeclaredPublicKey = publicKey;
    if (failPush) throw Exception('no route to host');
    return nextPushResult ??
        const PushResult(registration: 'none', outcomes: []);
  }

  @override
  Future<PullResult> pull({required String userId}) async {
    if (failPull) throw Exception('no route to host');
    return nextPullResult ?? const PullResult(transactions: []);
  }
}

extension on Transaction {
  Transaction withStatus(TransactionStatus newStatus) => Transaction(
        transactionId: transactionId,
        senderId: senderId,
        receiverId: receiverId,
        senderWalletId: senderWalletId,
        receiverWalletId: receiverWalletId,
        amount: amount,
        type: type,
        status: newStatus,
        description: description,
        nonce: nonce,
        senderPublicKey: senderPublicKey,
        signature: signature,
        rejectionReason: rejectionReason,
        timestamp: timestamp,
      );

  Transaction withAmount(double newAmount) => Transaction(
        transactionId: transactionId,
        senderId: senderId,
        receiverId: receiverId,
        senderWalletId: senderWalletId,
        receiverWalletId: receiverWalletId,
        amount: newAmount,
        type: type,
        status: status,
        description: description,
        nonce: nonce,
        senderPublicKey: senderPublicKey,
        signature: signature,
        timestamp: timestamp,
      );
}

SyncOutcome outcomeFor(
  Transaction tx,
  SyncOutcomeType type, {
  String? reason,
  String? code,
}) =>
    SyncOutcome(
      transactionId: tx.transactionId,
      outcomeType: type,
      serverStatus: type.name.toUpperCase(),
      reason: reason,
      code: code,
    );

void main() {
  sqfliteFfiInit();
  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  late LocalDatabase db;
  late FakeSyncTransport transport;
  late WalletProvider wallet;
  late User me;

  setUp(() async {
    db = LocalDatabase.inMemory();
    transport = FakeSyncTransport();
    wallet = WalletProvider(
      database: db,
      keyStore: InMemoryKeyStore(),
      syncTransport: transport,
    );
    await wallet.initialize();
    me = wallet.currentUser!;
  });

  tearDown(() => db.close());

  Future<Transaction> payOffline(double amount) => wallet.createOfflinePayment(
        receiverId: 'USER_bob',
        receiverWalletId: 'WALLET_bob',
        amount: amount,
        description: 'Offline payment',
      );

  /// A receipt signed by a REAL separate payer wallet, addressed to me -
  /// in the state the server would return it: already CONFIRMED on the
  /// payer's upload (status is not signed, so this stays verifiable).
  Future<Transaction> signedIncoming({double amount = 150}) async {
    final payerDb = LocalDatabase.inMemory();
    final payer =
        WalletProvider(database: payerDb, keyStore: InMemoryKeyStore());
    await payer.initialize();
    final tx = await payer.createOfflinePayment(
      receiverId: me.userId,
      receiverWalletId: me.walletId,
      amount: amount,
      description: 'Signed while offline',
    );
    await payerDb.close();
    return tx.withStatus(TransactionStatus.confirmed);
  }

  group('push (uploading the offline queue)', () {
    test('uploads every pending transaction and books a confirmation once',
        () async {
      final a = await payOffline(100);
      final b = await payOffline(50);
      expect(wallet.pendingSyncCount, 2);
      expect(wallet.availableBalance, 350); // seed 500 - 150 reserved

      transport.nextPushResult = PushResult(
        registration: 'bound',
        outcomes: [
          outcomeFor(a, SyncOutcomeType.confirmed),
          outcomeFor(b, SyncOutcomeType.confirmed),
        ],
      );

      final report = (await wallet.syncNow())!;

      expect(report.pushed, 2);
      expect(report.confirmed, 2);
      expect(transport.pushedBatches.single, hasLength(2));

      // Both rows settled...
      expect((await db.getTransactionById(a.transactionId))!.status,
          TransactionStatus.confirmed);
      expect((await db.getTransactionById(b.transactionId))!.status,
          TransactionStatus.confirmed);
      // ...and the balance moved WITHOUT a jump: the reservation simply
      // became a real debit (available was 350 before, stays 350 after).
      expect(wallet.confirmedBalance, 350);
      expect(wallet.pendingOutgoing, 0);
      expect(wallet.availableBalance, 350);
    });

    test('declares the device public key (server binds it trust-on-first-use)',
        () async {
      await wallet.ensureSigningKey();
      await payOffline(10);

      transport.nextPushResult = const PushResult(
        registration: 'already-bound',
        outcomes: [],
      );
      await wallet.syncNow();

      expect(transport.lastDeclaredPublicKey, wallet.publicKeyBase64);
    });

    test('DUPLICATE outcome confirms too (lost response, retried push)',
        () async {
      final tx = await payOffline(100);
      transport.nextPushResult = PushResult(
        registration: 'already-bound',
        outcomes: [
          outcomeFor(tx, SyncOutcomeType.duplicate,
              reason: 'server already has this copy'),
        ],
      );

      await wallet.syncNow();

      expect((await db.getTransactionById(tx.transactionId))!.status,
          TransactionStatus.confirmed);
      expect(wallet.confirmedBalance, 400);
      expect(wallet.availableBalance, 400);
    });

    test('REJECTED releases the reservation and stores the reason', () async {
      final tx = await payOffline(100);
      expect(wallet.availableBalance, 400);

      transport.nextPushResult = PushResult(
        registration: 'already-bound',
        outcomes: [
          outcomeFor(tx, SyncOutcomeType.rejected,
              reason: 'invalid signature'),
        ],
      );
      final report = (await wallet.syncNow())!;

      final stored = (await db.getTransactionById(tx.transactionId))!;
      expect(stored.status, TransactionStatus.rejected);
      expect(stored.rejectionReason, 'invalid signature');
      expect(report.rejected, 1);
      // The server refused the spend: the money is ours again.
      expect(wallet.confirmedBalance, 500);
      expect(wallet.availableBalance, 500);
    });

    test('CONFLICT also releases the reservation', () async {
      final tx = await payOffline(100);
      transport.nextPushResult = PushResult(
        registration: 'already-bound',
        outcomes: [
          outcomeFor(tx, SyncOutcomeType.conflict,
              reason: 'a different transaction with this id was accepted'),
        ],
      );
      final report = (await wallet.syncNow())!;

      expect((await db.getTransactionById(tx.transactionId))!.status,
          TransactionStatus.conflict);
      expect(report.conflicts, 1);
      expect(wallet.availableBalance, 500);
    });

    test('a network failure leaves the queue and balances untouched',
        () async {
      final tx = await payOffline(100);
      transport.failPush = true;

      final report = (await wallet.syncNow())!;

      expect(report.ok, isFalse);
      expect(report.errorMessage, contains('Push failed'));
      expect((await db.getTransactionById(tx.transactionId))!.status,
          TransactionStatus.pendingSync);
      expect(wallet.confirmedBalance, 500);
      expect(wallet.availableBalance, 400); // still reserved, nothing lost
    });
  });

  group('pull (learning what the server knows)', () {
    test('inserts a confirmed payment made to us while we were offline',
        () async {
      final incoming = await signedIncoming(amount: 150);
      transport.nextPullResult = PullResult(transactions: [incoming]);

      final report = (await wallet.syncNow())!;

      expect(report.pulledNew, 1);
      final stored = (await db.getTransactionById(incoming.transactionId))!;
      expect(stored.status, TransactionStatus.confirmed);
      // The server confirmed money arriving offline: it becomes ours.
      expect(wallet.confirmedBalance, 650);
      expect(
        wallet.transactions.any((t) => t.transactionId == incoming.transactionId),
        isTrue,
      );
    });

    test('skips a tampered pull (signature check on arrival)', () async {
      final incoming = await signedIncoming(amount: 150);
      // The transport (or anyone on the wire) edits the amount after
      // signing - exactly what cleartext HTTP invites.
      final tampered = incoming.withAmount(99999);
      transport.nextPullResult = PullResult(transactions: [tampered]);

      final report = (await wallet.syncNow())!;

      expect(report.skippedTampered, 1);
      expect(await db.getTransactionById(incoming.transactionId), isNull);
      expect(wallet.confirmedBalance, 500);
    });

    test('accepts an unsigned legacy incoming payment', () async {
      final legacy = Transaction(
        transactionId: 'TXN_legacy_1',
        senderId: 'USER_old_payer',
        receiverId: me.userId,
        senderWalletId: 'WALLET_old_payer',
        receiverWalletId: me.walletId,
        amount: 25,
        type: TransactionType.offlinePayment,
        status: TransactionStatus.confirmed,
        description: 'From a pre-Phase-5 build',
        nonce: 'nonce_legacy_1',
        timestamp: DateTime.now(),
      );
      transport.nextPullResult = PullResult(transactions: [legacy]);

      final report = (await wallet.syncNow())!;

      expect(report.pulledNew, 1);
      expect(wallet.confirmedBalance, 525);
    });

    test('ignores transactions that involve someone else', () async {
      final foreign = Transaction(
        transactionId: 'TXN_foreign_1',
        senderId: 'USER_a',
        receiverId: 'USER_b',
        senderWalletId: 'WALLET_a',
        receiverWalletId: 'WALLET_b',
        amount: 80,
        type: TransactionType.offlinePayment,
        status: TransactionStatus.confirmed,
        description: 'None of my business',
        nonce: 'nonce_foreign_1',
        timestamp: DateTime.now(),
      );
      transport.nextPullResult = PullResult(transactions: [foreign]);

      final report = (await wallet.syncNow())!;

      expect(report.skippedForeign, 1);
      expect(await db.getTransactionById('TXN_foreign_1'), isNull);
    });

    test('advances our own pending copy to confirmed - exactly once',
        () async {
      final tx = await payOffline(100);
      // The server already knows this payment (some other sync stored it).
      final confirmedCopy = tx.withStatus(TransactionStatus.confirmed);
      transport.nextPullResult = PullResult(transactions: [confirmedCopy]);

      await wallet.syncNow();
      expect((await db.getTransactionById(tx.transactionId))!.status,
          TransactionStatus.confirmed);
      expect(wallet.confirmedBalance, 400);

      // Syncing again with the same server view must NOT book it twice.
      transport.nextPullResult = PullResult(transactions: [confirmedCopy]);
      final report = (await wallet.syncNow())!;
      expect(report.pulledUpdated, 0);
      expect(wallet.confirmedBalance, 400);
    });

    test('a pull failure does not touch local state', () async {
      final tx = await payOffline(100);
      transport.failPull = true;

      final report = (await wallet.syncNow())!;

      expect(report.ok, isFalse);
      expect(report.errorMessage, contains('Pull failed'));
      expect((await db.getTransactionById(tx.transactionId))!.status,
          TransactionStatus.pendingSync);
      expect(wallet.availableBalance, 400);
    });
  });

  group('full cycle', () {
    test('push and pull run in one sync, in that order', () async {
      final outgoing = await payOffline(100);
      final incoming = await signedIncoming(amount: 40);

      transport.nextPushResult = PushResult(
        registration: 'bound',
        outcomes: [outcomeFor(outgoing, SyncOutcomeType.confirmed)],
      );
      transport.nextPullResult = PullResult(transactions: [incoming]);

      final report = (await wallet.syncNow())!;

      expect(report.pushed, 1);
      expect(report.confirmed, 1);
      expect(report.pulledNew, 1);
      // 500 seed - 100 sent + 40 received = 440.
      expect(wallet.confirmedBalance, 440);
      expect(wallet.availableBalance, 440);
      expect(wallet.pendingSyncCount, 0);
      expect(transport.pushedBatches, hasLength(1)); // push ran first
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 7: server-side balance arbitration, as seen from the device.
  //
  // The server tests live in backend/scripts/demo-phase7.js (clone
  // double-spend, onboarding, escrow, policy gates over real HTTP). Here
  // we verify what the app DOES with those verdicts.
  // ---------------------------------------------------------------------------
  group('server balance arbitration (Phase 7)', () {
    test('an INSUFFICIENT_BALANCE rejection corrects the local balance', () async {
      // The clone scenario in miniature: our ledger says 500, but the
      // server (already spent down by our twin) says otherwise.
      final tx = await payOffline(400);
      expect(wallet.availableBalance, 100);

      transport.nextPushResult = PushResult(
        registration: 'already-bound',
        balance: 100,
        outcomes: [
          outcomeFor(
            tx,
            SyncOutcomeType.rejected,
            reason: 'insufficient balance on the server: sender has 100, transaction needs 400',
            code: 'INSUFFICIENT_BALANCE',
          ),
        ],
      );
      final report = (await wallet.syncNow())!;

      final stored = (await db.getTransactionById(tx.transactionId))!;
      expect(stored.status, TransactionStatus.rejected);
      // The refusal releases the reservation (available = confirmed again)
      // and the balance itself is corrected to the authoritative number.
      expect(report.balanceCorrected, 100);
      expect(wallet.confirmedBalance, 100);
      expect(wallet.availableBalance, 100);
      expect(report.summary, contains('corrected'));
    });

    test('a rejection for any OTHER reason does not touch the balance',
        () async {
      final tx = await payOffline(100);
      transport.nextPushResult = PushResult(
        registration: 'already-bound',
        balance: 999, // even a wildly different number must be ignored
        outcomes: [
          outcomeFor(
            tx,
            SyncOutcomeType.rejected,
            reason: 'invalid signature: the transaction does not match what the payer signed',
            code: 'INVALID_SIGNATURE',
          ),
        ],
      );
      final report = (await wallet.syncNow())!;

      expect((await db.getTransactionById(tx.transactionId))!.status,
          TransactionStatus.rejected);
      expect(report.balanceCorrected, isNull);
      expect(wallet.confirmedBalance, 500); // local view untouched
      expect(wallet.availableBalance, 500); // reservation released only
    });

    test('the balance field alone never overrides local bookkeeping',
        () async {
      final tx = await payOffline(100);
      transport.nextPushResult = PushResult(
        registration: 'already-bound',
        balance: 480, // disagrees with our 400, but nothing was refused
        outcomes: [outcomeFor(tx, SyncOutcomeType.confirmed)],
      );
      final report = (await wallet.syncNow())!;

      expect(wallet.confirmedBalance, 400); // booked from the verdict...
      expect(report.balanceCorrected, isNull); // ...not from the field
    });

    test('a mixed batch settles each way at once', () async {
      // Both spends are creatable LOCALLY (500 - reserves = 100 left), but
      // the server starts this push at only 150: the twin already spent
      // 350 of the shared balance before we synced.
      final ok = await payOffline(100);
      final tooMuch = await payOffline(300);

      transport.nextPushResult = PushResult(
        registration: 'already-bound',
        balance: 50, // 150 - 100 confirmed, then the 300 was refused
        outcomes: [
          outcomeFor(ok, SyncOutcomeType.confirmed),
          outcomeFor(
            tooMuch,
            SyncOutcomeType.rejected,
            reason: 'insufficient balance on the server: sender has 50, transaction needs 300',
            code: 'INSUFFICIENT_BALANCE',
          ),
        ],
      );
      final report = (await wallet.syncNow())!;

      expect((await db.getTransactionById(ok.transactionId))!.status,
          TransactionStatus.confirmed);
      expect((await db.getTransactionById(tooMuch.transactionId))!.status,
          TransactionStatus.rejected);
      // Local view said 400 after the first confirmation - the server's
      // authoritative 50 wins because a spend was refused.
      expect(wallet.confirmedBalance, 50);
      expect(wallet.availableBalance, 50);
      expect(wallet.pendingSyncCount, 0);
      expect(report.balanceCorrected, 50);
    });

    test('first-ever push reports the onboarding verdict', () async {
      await payOffline(50);
      transport.nextPushResult = const PushResult(
        registration: 'created',
        balance: 450,
        outcomes: [],
      );
      final report = (await wallet.syncNow())!;

      expect(report.onboarded, isTrue);
      expect(report.summary, contains('registered'));
    });

    test('SyncOutcome decodes the wire code field', () {
      final outcome = SyncOutcome.fromJson({
        'transactionId': 'TXN_x',
        'outcome': 'REJECTED',
        'serverStatus': 'REJECTED',
        'reason': 'insufficient balance on the server: sender has 0, transaction needs 5',
        'code': 'INSUFFICIENT_BALANCE',
      });
      expect(outcome.code, 'INSUFFICIENT_BALANCE');
      expect(outcome.outcomeType, SyncOutcomeType.rejected);
      // Older servers (or plain rejections) simply omit the field.
      expect(
        SyncOutcome.fromJson({
          'transactionId': 'TXN_y',
          'outcome': 'REJECTED',
        }).code,
        isNull,
      );
    });
  });
}
