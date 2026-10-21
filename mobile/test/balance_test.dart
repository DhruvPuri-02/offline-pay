import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/models/transaction.dart';
import 'package:offlinepay/utils/balance.dart';

Transaction _tx({
  required String id,
  required String sender,
  required String receiver,
  required double amount,
  TransactionStatus status = TransactionStatus.pendingSync,
}) {
  return Transaction(
    transactionId: id,
    senderId: sender,
    receiverId: receiver,
    senderWalletId: 'WALLET_S_$sender',
    receiverWalletId: 'WALLET_R_$receiver',
    amount: amount,
    type: TransactionType.offlinePayment,
    status: status,
    description: 'test',
    timestamp: DateTime(2026, 1, 1),
  );
}

void main() {
  group('computeBalance', () {
    test('pending outgoing reduces available balance', () {
      // Spec section 10: 500 - 100 - 50 = 350
      final summary = computeBalance(
        confirmed: 500,
        transactions: [
          _tx(id: '1', sender: 'alice', receiver: 'bob', amount: 100),
          _tx(id: '2', sender: 'alice', receiver: 'charlie', amount: 50),
        ],
        userId: 'alice',
      );

      expect(summary.confirmed, 500);
      expect(summary.pendingOutgoing, 150);
      expect(summary.available, 350);
      expect(summary.pendingIncoming, 0);
    });

    test('pending incoming does NOT increase available balance', () {
      // Receiving money offline is unconfirmed: the sender's device may
      // have spent the same funds elsewhere. Counting it would enable
      // double-spending of unconfirmed receipts.
      final summary = computeBalance(
        confirmed: 500,
        transactions: [
          _tx(id: '1', sender: 'charlie', receiver: 'alice', amount: 80),
        ],
        userId: 'alice',
      );

      expect(summary.pendingIncoming, 80);
      expect(summary.available, 500);
    });

    test('confirmed transactions are excluded from pending maths', () {
      final summary = computeBalance(
        confirmed: 500,
        transactions: [
          _tx(
            id: '1',
            sender: 'alice',
            receiver: 'bob',
            amount: 100,
            status: TransactionStatus.confirmed,
          ),
        ],
        userId: 'alice',
      );

      expect(summary.pendingOutgoing, 0);
      expect(summary.available, 500);
    });

    test('rejected transactions do not reserve balance', () {
      final summary = computeBalance(
        confirmed: 500,
        transactions: [
          _tx(
            id: '1',
            sender: 'alice',
            receiver: 'bob',
            amount: 400,
            status: TransactionStatus.rejected,
          ),
        ],
        userId: 'alice',
      );

      expect(summary.available, 500);
    });
  });

  group('validateOfflinePayment - double-spend prevention', () {
    test('the spec double-spend scenario is caught locally', () {
      // Alice has 500 and tries to pay 400 twice while offline.
      const max = 500.0;
      var available = 500.0;

      final first = validateOfflinePayment(
        amount: 400,
        available: available,
        senderId: 'alice',
        receiverId: 'bob',
        maxOfflineAmount: max,
      );
      expect(first.allowed, isTrue);

      // Reserve the funds, exactly as the ledger does after creation.
      available -= 400;

      final second = validateOfflinePayment(
        amount: 400,
        available: available,
        senderId: 'alice',
        receiverId: 'charlie',
        maxOfflineAmount: max,
      );
      expect(second.allowed, isFalse);
      expect(second.reason, contains('Insufficient available offline balance'));
    });

    test('rejects paying yourself', () {
      final decision = validateOfflinePayment(
        amount: 10,
        available: 100,
        senderId: 'alice',
        receiverId: 'alice',
        maxOfflineAmount: 500,
      );
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains('Cannot pay yourself'));
    });

    test('rejects amounts above the offline per-transaction cap', () {
      final decision = validateOfflinePayment(
        amount: 600,
        available: 1000,
        senderId: 'alice',
        receiverId: 'bob',
        maxOfflineAmount: 500,
      );
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains('limited to'));
    });

    test('rejects zero and negative amounts', () {
      for (final amount in [0.0, -5.0]) {
        final decision = validateOfflinePayment(
          amount: amount,
          available: 100,
          senderId: 'alice',
          receiverId: 'bob',
          maxOfflineAmount: 500,
        );
        expect(decision.allowed, isFalse, reason: 'amount $amount must fail');
      }
    });

    test('allows a payment that exactly matches the available balance', () {
      final decision = validateOfflinePayment(
        amount: 100,
        available: 100,
        senderId: 'alice',
        receiverId: 'bob',
        maxOfflineAmount: 500,
      );
      expect(decision.allowed, isTrue);
    });
  });
}
