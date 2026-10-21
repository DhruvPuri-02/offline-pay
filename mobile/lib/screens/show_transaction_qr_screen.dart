import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/transaction.dart';
import '../models/qr_message.dart';

/// Shown to the PAYER right after an offline payment is created.
///
/// It displays the full transaction as a QR code (message type 2,
/// TRANSACTION_RECEIPT). The receiver scans this to book the incoming
/// payment - which is how the money actually crosses between devices
/// without internet. Until the receiver scans it, only the payer's ledger
/// knows about the transaction.
class ShowTransactionQRScreen extends StatelessWidget {
  const ShowTransactionQRScreen({super.key, required this.transaction});

  final Transaction transaction;

  @override
  Widget build(BuildContext context) {
    final receiptJson = encodeTransactionReceipt(transaction);

    return Scaffold(
      appBar: AppBar(title: const Text('Payment Created')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Text(
              'Show this QR to the receiver',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            const Text(
              'They scan it in Receive → Scan incoming payment.\nNo internet needed.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 24),

            // QR itself - white card, QR codes need high contrast.
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: QrImageView(
                  data: receiptJson,
                  version: QrVersions.auto,
                  size: 260.0,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 24),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _row('Amount', '₹${transaction.amount.toStringAsFixed(2)}'),
                    const Divider(),
                    _row('To wallet', transaction.receiverWalletId),
                    const Divider(),
                    _row('Description', transaction.description),
                    const Divider(),
                    _row('Transaction ID', transaction.transactionId),
                    const Divider(),
                    _row(
                      'Signature',
                      transaction.signature != null
                          ? 'signed (${_keyFingerprint(transaction.senderPublicKey)})'
                          : 'not signed',
                    ),
                    const Divider(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Status',
                            style: TextStyle(color: Colors.grey)),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'PENDING SYNC',
                            style: TextStyle(
                              color: Colors.orange,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            OutlinedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy transaction JSON'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: receiptJson));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')),
                  );
                }
              },
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  /// Short slice of the signing public key (base64) - long enough for a
  /// human to compare two devices, short enough to fit the card.
  static String _keyFingerprint(String? publicKeyBase64) {
    if (publicKeyBase64 == null || publicKeyBase64.length < 8) {
      return 'unknown key';
    }
    return 'key ${publicKeyBase64.substring(0, 8)}';
  }
}
