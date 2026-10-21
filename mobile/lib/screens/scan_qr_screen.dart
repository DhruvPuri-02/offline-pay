import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/qr_message.dart';
import '../models/qr_payload.dart';
import '../providers/wallet_provider.dart';
import '../utils/payment_exception.dart';
import '../widgets/qr_scanner_view.dart';
import 'show_transaction_qr_screen.dart';

/// Payer side of the receiver-initiated flow (spec section 6):
///
///   Bob opens Receive -> shows PAYMENT_REQUEST QR (has the amount in it)
///   Alice opens Scan  -> reads it -> confirms -> transaction is created
///                        locally as PENDING_SYNC -> receipt QR appears
///   Bob scans the receipt to book it on his device.
///
/// Every step above happens with no internet connection.
class ScanQRScreen extends StatefulWidget {
  const ScanQRScreen({super.key});

  @override
  State<ScanQRScreen> createState() => _ScanQRScreenState();
}

class _ScanQRScreenState extends State<ScanQRScreen> {
  QRPayload? _request;
  bool _submitting = false;

  void _onScanned(String raw) {
    if (_submitting) return;

    try {
      final message = QrMessage.decode(raw);
      switch (message) {
        case PaymentRequestMessage(:final payload):
          if (payload.isExpired) {
            _showError('This payment request has expired. Ask for a new QR.');
            return;
          }
          setState(() => _request = payload);
        case TransactionReceiptMessage():
          _showError(
            'That is a payment receipt, not a payment request. '
            'Receipts are scanned in Receive → Scan incoming payment.',
          );
      }
    } on FormatException catch (e) {
      _showError(e.message);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  Future<void> _confirmPayment() async {
    final request = _request;
    if (request == null || _submitting) return;

    final wallet = context.read<WalletProvider>();
    setState(() => _submitting = true);

    try {
      // Phase 4: the transaction PIN prompt goes HERE, before creation.
      //
      // Note the nonce: it comes from Bob's request QR, so paying the same
      // request twice produces the same nonce - and the backend's unique
      // index rejects the second one at sync time.
      final tx = await wallet.createOfflinePayment(
        receiverId: request.receiverId,
        receiverWalletId: request.receiverWalletId,
        amount: request.amount,
        description: request.description,
        nonce: request.nonce,
      );

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => ShowTransactionQRScreen(transaction: tx)),
      );
    } on PaymentException catch (e) {
      _showError(e.reason);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _reset() {
    setState(() => _request = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Payment QR')),
      body: _request == null
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: QrScannerView(onValueScanned: _onScanned),
            )
          : _buildConfirmation(context),
    );
  }

  Widget _buildConfirmation(BuildContext context) {
    final request = _request!;
    final wallet = context.watch<WalletProvider>();
    final after = wallet.availableBalance - request.amount;
    final willFail = request.amount > wallet.availableBalance;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const Icon(Icons.qr_code_2, size: 72),
          const SizedBox(height: 16),
          Text('Confirm Payment',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _row('Pay to', request.receiverName),
                  const Divider(),
                  _row('Wallet', request.receiverWalletId),
                  const Divider(),
                  _row('Amount', '₹${request.amount.toStringAsFixed(2)}'),
                  const Divider(),
                  _row('Description', request.description),
                  const Divider(),
                  _row('Your available', '₹${wallet.availableBalance.toStringAsFixed(2)}'),
                  const Divider(),
                  _row(
                    'After payment',
                    '₹${after < 0 ? 0 : after.toStringAsFixed(2)}',
                    warn: willFail,
                  ),
                ],
              ),
            ),
          ),
          if (willFail) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red),
              ),
              child: const Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Insufficient available offline balance. This payment will be rejected.',
                      style: TextStyle(color: Colors.red, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _submitting ? null : _confirmPayment,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.all(16),
            ),
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Confirm Payment'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _submitting ? null : _reset,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool warn = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: warn ? Colors.red : null,
            ),
          ),
        ),
      ],
    );
  }
}
