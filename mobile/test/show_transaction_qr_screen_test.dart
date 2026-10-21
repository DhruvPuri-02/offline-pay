import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offlinepay/models/transaction.dart';
import 'package:offlinepay/screens/show_transaction_qr_screen.dart';

/// Phase 5 UI: the payer's receipt advertises what was signed.
void main() {
  Transaction receipt({String? signature, String? publicKey}) => Transaction(
        transactionId: 'TX_ui_1',
        senderId: 'USER_alice',
        receiverId: 'USER_bob',
        senderWalletId: 'WALLET_alice',
        receiverWalletId: 'WALLET_bob',
        amount: 100,
        type: TransactionType.offlinePayment,
        status: TransactionStatus.pendingSync,
        description: 'UI test',
        nonce: 'nonce_ui_1',
        signature: signature,
        senderPublicKey: publicKey,
        timestamp: DateTime.utc(2026, 1, 15),
      );

  testWidgets('a signed receipt shows a key fingerprint', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ShowTransactionQRScreen(
        transaction: receipt(
          signature: 'sig',
          publicKey: 'QUJDREVGR0g=',
        ),
      ),
    ));

    expect(find.text('signed (key QUJDREVG)'), findsOneWidget);
    expect(find.text('not signed'), findsNothing);
  });

  testWidgets('an unsigned receipt admits it', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ShowTransactionQRScreen(transaction: receipt()),
    ));

    expect(find.text('not signed'), findsOneWidget);
  });
}
