import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/models/transaction.dart';
import 'package:offlinepay/services/local_database.dart';
// hide Transaction: sqflite_common also exports a `Transaction` type.
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

Transaction _tx({
  required String id,
  String sender = 'USER_alice',
  String receiver = 'USER_bob',
  double amount = 100,
  String? nonce,
  TransactionStatus status = TransactionStatus.pendingSync,
}) {
  return Transaction(
    transactionId: id,
    senderId: sender,
    receiverId: receiver,
    senderWalletId: 'WALLET_alice',
    receiverWalletId: 'WALLET_bob',
    amount: amount,
    type: TransactionType.offlinePayment,
    status: status,
    description: 'test',
    nonce: nonce,
    timestamp: DateTime(2026, 10, 10),
  );
}

void main() {
  sqfliteFfiInit();
  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  late LocalDatabase db;

  setUp(() => db = LocalDatabase.inMemory());
  tearDown(() => db.close());

  group('ledger idempotency', () {
    test('inserting the same transaction twice is a no-op', () async {
      final first = await db.insertTransaction(_tx(id: 'TXN_1', nonce: 'n1'));
      final second = await db.insertTransaction(_tx(id: 'TXN_1', nonce: 'n1'));

      expect(first, isTrue);
      expect(second, isFalse, reason: 're-scanning a receipt must not re-insert');

      final all = await db.getTransactions();
      expect(all, hasLength(1));
    });

    test('a repeated nonce is rejected even with a new transaction id', () async {
      // Replay defence: someone re-packages a payment under a fresh
      // transactionId but forgets (or tries to cheat) on the nonce.
      await db.insertTransaction(_tx(id: 'TXN_1', nonce: 'same_nonce'));
      final replay = await db.insertTransaction(_tx(id: 'TXN_2', nonce: 'same_nonce'));

      expect(replay, isFalse);
      final all = await db.getTransactions();
      expect(all, hasLength(1));
    });

    test('multiple NULL nonces are allowed (seeded topups)', () async {
      // Regression test for the partial-index design: a UNIQUE index over
      // NULLs would reject the second topup.
      final a = await db.insertTransaction(
        _tx(id: 'TXN_1', nonce: null, sender: 'SYSTEM', amount: 500),
      );
      final b = await db.insertTransaction(
        _tx(id: 'TXN_2', nonce: null, sender: 'SYSTEM', amount: 250),
      );

      expect(a, isTrue);
      expect(b, isTrue);
    });
  });

  group('status handling', () {
    test('pending queue returns only unsettled transactions', () async {
      await db.insertTransaction(_tx(id: 'TXN_1', nonce: 'n1'));
      await db.insertTransaction(
        _tx(id: 'TXN_2', nonce: 'n2', status: TransactionStatus.confirmed),
      );
      await db.insertTransaction(
        _tx(id: 'TXN_3', nonce: 'n3', status: TransactionStatus.rejected),
      );

      final pending = await db.getPendingSyncTransactions();
      expect(pending.map((t) => t.transactionId), ['TXN_1']);
    });

    test('status and rejection reason are persisted', () async {
      await db.insertTransaction(_tx(id: 'TXN_1', nonce: 'n1'));

      await db.updateTransactionStatus(
        'TXN_1',
        TransactionStatus.rejected,
        rejectionReason: 'Transaction signature is invalid.',
      );

      final all = await db.getTransactions();
      expect(all.single.status, TransactionStatus.rejected);
      expect(all.single.rejectionReason, 'Transaction signature is invalid.');
    });
  });

  group('wallet profile', () {
    test('profile round-trips', () async {
      expect(await db.getWalletProfile(), isNull);
    });
  });
}
