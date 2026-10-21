import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/models/qr_message.dart';
import 'package:offlinepay/models/qr_payload.dart';
import 'package:offlinepay/models/transaction.dart';

void main() {
  final receipt = Transaction(
    transactionId: 'TXN_test123',
    senderId: 'USER_alice',
    receiverId: 'USER_bob',
    senderWalletId: 'WALLET_alice',
    receiverWalletId: 'WALLET_bob',
    amount: 100,
    type: TransactionType.offlinePayment,
    status: TransactionStatus.pendingSync,
    description: 'Chai',
    nonce: 'nonce_abc',
    timestamp: DateTime(2026, 10, 10, 12, 30),
  );

  group('QrMessage.decode', () {
    test('receipt round-trips through encode -> decode', () {
      final decoded = QrMessage.decode(encodeTransactionReceipt(receipt));

      expect(decoded, isA<TransactionReceiptMessage>());
      final tx = (decoded as TransactionReceiptMessage).transaction;
      expect(tx.transactionId, receipt.transactionId);
      expect(tx.amount, 100);
      expect(tx.receiverWalletId, 'WALLET_bob');
      expect(tx.status, TransactionStatus.pendingSync);
      expect(tx.nonce, 'nonce_abc');
      expect(tx.description, 'Chai');
    });

    test('payment request JSON decodes', () {
      final request = QRPayload(
        receiverId: 'USER_bob',
        receiverName: 'Bob',
        receiverWalletId: 'WALLET_bob',
        amount: 42,
        description: 'Lunch',
        nonce: 'req_nonce',
      );

      final decoded = QrMessage.decode(jsonEncode(request.toJson()));
      expect(decoded, isA<PaymentRequestMessage>());
      expect((decoded as PaymentRequestMessage).payload.amount, 42);
    });

    test('garbage input throws a readable FormatException', () {
      expect(
        () => QrMessage.decode('not json at all'),
        throwsA(isA<FormatException>()),
      );
    });

    test('JSON that is not an object throws FormatException', () {
      expect(
        () => QrMessage.decode('[1,2,3]'),
        throwsA(isA<FormatException>()),
      );
    });

    test('unknown type throws FormatException', () {
      expect(
        () => QrMessage.decode('{"type":"SOMETHING_ELSE"}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('receipt without transaction payload throws FormatException', () {
      expect(
        () => QrMessage.decode('{"type":"TRANSACTION_RECEIPT"}'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
