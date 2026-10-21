import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/models/transaction.dart';
import 'package:offlinepay/models/user.dart';
import 'package:offlinepay/providers/wallet_provider.dart';
import 'package:offlinepay/services/local_database.dart';
import 'package:offlinepay/services/secure_key_store.dart';
import 'package:offlinepay/utils/payment_exception.dart';
// hide Transaction: sqflite_common also exports a `Transaction` type.
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

void main() {
  sqfliteFfiInit();
  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  late LocalDatabase db;
  late WalletProvider wallet;

  setUp(() async {
    db = LocalDatabase.inMemory();
    // Phase 5: tests have no platform keystore (flutter_secure_storage
    // needs real plugins), so payments sign with an in-memory key store.
    wallet = WalletProvider(database: db, keyStore: InMemoryKeyStore());
    await wallet.initialize();
  });

  tearDown(() => db.close());

  group('first-run wallet', () {
    test('seeds a local demo wallet with no network', () {
      expect(wallet.isInitialized, isTrue);
      expect(wallet.currentUser, isNotNull);
      expect(wallet.confirmedBalance, WalletProvider.firstRunSeedBalance);
      expect(wallet.availableBalance, WalletProvider.firstRunSeedBalance);
      // The seed money must be explained by a ledger entry.
      expect(wallet.transactions, hasLength(1));
      expect(wallet.transactions.single.type, TransactionType.topup);
    });

    test('a second initialize does not re-seed', () async {
      await wallet.initialize();
      expect(wallet.confirmedBalance, WalletProvider.firstRunSeedBalance);
      expect(wallet.transactions, hasLength(1));
    });
  });

  group('createOfflinePayment', () {
    test('stores the payment as PENDING_SYNC and reserves the balance', () async {
      final tx = await wallet.createOfflinePayment(
        receiverId: 'USER_bob',
        receiverWalletId: 'WALLET_bob',
        amount: 100,
        description: 'Chai',
      );

      expect(tx.status, TransactionStatus.pendingSync);
      expect(wallet.pendingOutgoing, 100);
      expect(wallet.availableBalance, 400);
      expect(wallet.pendingSyncTransactions, hasLength(1));

      // Survives a reload from disk (Phase 3: state is on SQLite, not RAM).
      await wallet.reload();
      expect(wallet.availableBalance, 400);
      expect(wallet.transactions, hasLength(2));
    });

    test('rejects spending more than available (double-spend scenario)', () async {
      await wallet.createOfflinePayment(
        receiverId: 'USER_bob',
        receiverWalletId: 'WALLET_bob',
        amount: 400,
      );

      expect(
        () => wallet.createOfflinePayment(
          receiverId: 'USER_charlie',
          receiverWalletId: 'WALLET_charlie',
          amount: 400,
        ),
        throwsA(
          isA<PaymentException>().having(
            (e) => e.reason,
            'reason',
            contains('Insufficient available offline balance'),
          ),
        ),
      );

      // Nothing was written for the refused payment.
      expect(wallet.pendingOutgoing, 400);
      expect(wallet.pendingSyncTransactions, hasLength(1));
    });

    test('rejects amounts above the offline cap', () async {
      expect(
        () => wallet.createOfflinePayment(
          receiverId: 'USER_bob',
          receiverWalletId: 'WALLET_bob',
          amount: 501,
        ),
        throwsA(isA<PaymentException>()),
      );
    });

    test('rejects paying yourself', () async {
      expect(
        () => wallet.createOfflinePayment(
          receiverId: wallet.currentUser!.userId,
          receiverWalletId: wallet.currentUser!.walletId,
          amount: 10,
        ),
        throwsA(isA<PaymentException>()),
      );
    });
  });

  group('recordIncomingPayment', () {
    Transaction receiptFor(User me) => Transaction(
          transactionId: 'TXN_in_1',
          senderId: 'USER_bob',
          receiverId: me.userId,
          senderWalletId: 'WALLET_bob',
          receiverWalletId: me.walletId,
          amount: 75,
          type: TransactionType.offlinePayment,
          status: TransactionStatus.pendingSync,
          description: 'Thanks',
          nonce: 'nonce_in_1',
          timestamp: DateTime(2026, 10, 10),
        );

    test('records a payment and flags it pending, without crediting available',
        () async {
      final isNew = await wallet.recordIncomingPayment(receiptFor(wallet.currentUser!));

      expect(isNew, isTrue);
      expect(wallet.pendingIncoming, 75);
      expect(
        wallet.availableBalance,
        WalletProvider.firstRunSeedBalance,
        reason: 'unconfirmed money must not be spendable',
      );
    });

    test('scanning the same receipt twice credits nothing twice', () async {
      await wallet.recordIncomingPayment(receiptFor(wallet.currentUser!));
      final again = await wallet.recordIncomingPayment(receiptFor(wallet.currentUser!));

      expect(again, isFalse);
      expect(wallet.pendingIncoming, 75);
      // Note: receivedTransactions also contains the seed TOPUP, so count
      // only the receipt we just scanned.
      expect(
        wallet.receivedTransactions
            .where((t) => t.transactionId == 'TXN_in_1'),
        hasLength(1),
      );
    });

    test('rejects a receipt addressed to another wallet', () async {
      final foreign = receiptFor(wallet.currentUser!).copyWithReceiver('USER_eve');

      expect(
        () => wallet.recordIncomingPayment(foreign),
        throwsA(
          isA<PaymentException>().having(
            (e) => e.reason,
            'reason',
            contains('different wallet'),
          ),
        ),
      );
    });
  });
}

extension on Transaction {
  Transaction copyWithReceiver(String receiverId) => Transaction(
        transactionId: transactionId,
        senderId: senderId,
        receiverId: receiverId,
        senderWalletId: senderWalletId,
        receiverWalletId: receiverWalletId,
        amount: amount,
        type: type,
        status: status,
        description: description,
        nonce: nonce,
        timestamp: timestamp,
      );
}
