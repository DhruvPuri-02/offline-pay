import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/models/transaction.dart';
import 'package:offlinepay/providers/wallet_provider.dart';
import 'package:offlinepay/services/local_database.dart';
import 'package:offlinepay/services/secure_key_store.dart';
import 'package:offlinepay/services/signature_service.dart';
import 'package:offlinepay/utils/payment_exception.dart';
// hide Transaction: sqflite_common also exports a `Transaction` type.
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

/// Phase 5 end-to-end: signing inside the wallet, verification on the
/// receiving side - against a real in-memory SQLite and in-memory key
/// stores that play the roles of two separate devices.
void main() {
  sqfliteFfiInit();
  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  late LocalDatabase db;
  late InMemoryKeyStore keyStore;
  late WalletProvider wallet;

  setUp(() async {
    db = LocalDatabase.inMemory();
    keyStore = InMemoryKeyStore();
    wallet = WalletProvider(database: db, keyStore: keyStore);
    await wallet.initialize();
  });

  tearDown(() => db.close());

  group('signing inside createOfflinePayment', () {
    test('attaches a verifiable signature and the wallet public key',
        () async {
      final tx = await wallet.createOfflinePayment(
        receiverId: 'USER_bob',
        receiverWalletId: 'WALLET_bob',
        amount: 100,
        description: 'Chai',
      );

      expect(tx.signature, isNotNull);
      expect(tx.senderPublicKey, isNotNull);
      expect(tx.senderPublicKey, wallet.publicKeyBase64);

      // The signature really verifies over the canonical payload.
      expect(
        await SignatureService.verify(
          SignatureService.canonicalPayload(tx),
          signatureBase64: tx.signature!,
          publicKeyBase64: tx.senderPublicKey!,
        ),
        isTrue,
      );
    });

    test('signing key is created lazily on the first payment', () async {
      expect(wallet.hasSigningKey, isFalse); // boot never touches the store
      expect(await keyStore.read(SignatureService.privateKeySeedKey), isNull);

      await wallet.createOfflinePayment(
        receiverId: 'USER_bob',
        receiverWalletId: 'WALLET_bob',
        amount: 50,
      );

      expect(wallet.hasSigningKey, isTrue);
      // Seed went to the secure store - not SQLite, not memory-only.
      expect(await keyStore.read(SignatureService.privateKeySeedKey),
          isNotNull);
    });

    test('all payments from one wallet share the same public key',
        () async {
      final a = await wallet.createOfflinePayment(
          receiverId: 'USER_bob', receiverWalletId: 'WALLET_bob', amount: 10);
      final b = await wallet.createOfflinePayment(
          receiverId: 'USER_bob', receiverWalletId: 'WALLET_bob', amount: 20);
      expect(a.senderPublicKey, b.senderPublicKey);
    });

    test('a signature survives an app restart (key reloaded from storage)',
        () async {
      final tx = await wallet.createOfflinePayment(
        receiverId: 'USER_bob',
        receiverWalletId: 'WALLET_bob',
        amount: 100,
      );
      final originalKey = wallet.publicKeyBase64;

      // "Restart": fresh provider, same database and same key store.
      final restarted =
          WalletProvider(database: db, keyStore: keyStore);
      await restarted.initialize();
      expect(restarted.publicKeyBase64, isNull); // lazy again...
      expect(await restarted.ensureSigningKey(), originalKey); // ...same key

      expect(
        await SignatureService.verify(
          SignatureService.canonicalPayload(tx),
          signatureBase64: tx.signature!,
          publicKeyBase64: tx.senderPublicKey!,
        ),
        isTrue,
      );
    });
  });

  group('recordIncomingPayment signature checks', () {
    /// A receipt signed by a REAL payer wallet, addressed to [receiverId].
    Future<Transaction> signedReceiptFromPayer({
      required String receiverId,
      required String receiverWalletId,
      double amount = 150,
      Transaction Function(Transaction)? tamper,
    }) async {
      final payerDb = LocalDatabase.inMemory();
      final payer = WalletProvider(
          database: payerDb, keyStore: InMemoryKeyStore());
      await payer.initialize();
      final tx = await payer.createOfflinePayment(
        receiverId: receiverId,
        receiverWalletId: receiverWalletId,
        amount: amount,
        description: 'Signed receipt',
      );
      await payerDb.close();
      // Optional tampering AFTER signing - exactly what an attacker who
      // edits the QR between the two devices would do.
      return tamper == null ? tx : tamper(tx);
    }

    test('a genuine signed receipt is recorded', () async {
      final me = wallet.currentUser!;
      final tx = await signedReceiptFromPayer(
        receiverId: me.userId,
        receiverWalletId: me.walletId,
      );

      expect(await wallet.recordIncomingPayment(tx), isTrue);
      expect(
        wallet.transactions.any((t) => t.transactionId == tx.transactionId),
        isTrue,
      );
    });

    test('a tampered amount invalidates the signature and is refused',
        () async {
      final me = wallet.currentUser!;
      final tx = await signedReceiptFromPayer(
        receiverId: me.userId,
        receiverWalletId: me.walletId,
        tamper: (t) => t.copyWithAmount(100000), // attack: bump the amount
      );

      await expectLater(
        wallet.recordIncomingPayment(tx),
        throwsA(predicate<PaymentException>(
            (e) => e.reason.contains('signature is invalid'))),
      );
      expect(
        wallet.transactions.any((t) => t.transactionId == tx.transactionId),
        isFalse,
        reason: 'a refused receipt must leave no ledger entry',
      );
    });

    test('a tampered receiver is refused', () async {
      final me = wallet.currentUser!;
      final tx = await signedReceiptFromPayer(
        receiverId: me.userId,
        receiverWalletId: me.walletId,
        tamper: (t) => t.copyWithReceiver('USER_mallory'),
      );

      await expectLater(
        wallet.recordIncomingPayment(tx),
        throwsA(predicate<PaymentException>(
            (e) => e.reason.contains('signature is invalid'))),
      );
    });

    test('a tampered description is refused (it is covered too)', () async {
      final me = wallet.currentUser!;
      final tx = await signedReceiptFromPayer(
        receiverId: me.userId,
        receiverWalletId: me.walletId,
        tamper: (t) => t.copyWithDescription('actually a loan repayment'),
      );

      await expectLater(
        wallet.recordIncomingPayment(tx),
        throwsA(predicate<PaymentException>(
            (e) => e.reason.contains('signature is invalid'))),
      );
    });

    test('a receipt with a signature but no public key is refused', () async {
      final me = wallet.currentUser!;
      final tx = await signedReceiptFromPayer(
        receiverId: me.userId,
        receiverWalletId: me.walletId,
        tamper: (t) => t.copyWithPublicKey(null),
      );

      await expectLater(
        wallet.recordIncomingPayment(tx),
        throwsA(predicate<PaymentException>(
            (e) => e.reason.contains('incomplete signature'))),
      );
    });

    test('an unsigned receipt is still accepted (older app version)',
        () async {
      final me = wallet.currentUser!;
      final signed = await signedReceiptFromPayer(
        receiverId: me.userId,
        receiverWalletId: me.walletId,
      );
      final unsigned = Transaction(
        transactionId: signed.transactionId,
        senderId: signed.senderId,
        receiverId: signed.receiverId,
        senderWalletId: signed.senderWalletId,
        receiverWalletId: signed.receiverWalletId,
        amount: signed.amount,
        type: signed.type,
        status: signed.status,
        description: signed.description,
        nonce: signed.nonce,
        timestamp: signed.timestamp,
        // no signature, no public key - the Phase 1-3 shape
      );

      expect(await wallet.recordIncomingPayment(unsigned), isTrue);
    });
  });
}

/// Small helpers so the tampering tests read like an attack narrative.
extension on Transaction {
  Transaction copyWithAmount(double newAmount) => Transaction(
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

  Transaction copyWithReceiver(String newReceiver) => Transaction(
        transactionId: transactionId,
        senderId: senderId,
        receiverId: newReceiver,
        senderWalletId: senderWalletId,
        receiverWalletId: receiverWalletId,
        amount: amount,
        type: type,
        status: status,
        description: description,
        nonce: nonce,
        senderPublicKey: senderPublicKey,
        signature: signature,
        timestamp: timestamp,
      );

  Transaction copyWithDescription(String newDescription) => Transaction(
        transactionId: transactionId,
        senderId: senderId,
        receiverId: receiverId,
        senderWalletId: senderWalletId,
        receiverWalletId: receiverWalletId,
        amount: amount,
        type: type,
        status: status,
        description: newDescription,
        nonce: nonce,
        senderPublicKey: senderPublicKey,
        signature: signature,
        timestamp: timestamp,
      );

  Transaction copyWithPublicKey(String? newKey) => Transaction(
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
        senderPublicKey: newKey,
        signature: signature,
        timestamp: timestamp,
      );
}
