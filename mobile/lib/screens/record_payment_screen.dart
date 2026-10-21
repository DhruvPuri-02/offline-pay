import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/qr_message.dart';
import '../models/transaction.dart';
import '../providers/wallet_provider.dart';
import '../utils/payment_exception.dart';
import '../widgets/qr_scanner_view.dart';

/// Receiver side of the receipt hand-off.
///
/// The payer finished creating the transaction and is showing a
/// TRANSACTION_RECEIPT QR. Scanning it here writes the incoming payment
/// into THIS device's ledger as PENDING_SYNC - no server involved.
///
/// Idempotency: `recordIncomingPayment` returns false when the same
/// transaction id is already stored, so re-scanning never credits twice.
class RecordPaymentScreen extends StatefulWidget {
  const RecordPaymentScreen({super.key});

  @override
  State<RecordPaymentScreen> createState() => _RecordPaymentScreenState();
}

class _RecordPaymentScreenState extends State<RecordPaymentScreen> {
  Transaction? _pending;
  bool _submitting = false;
  String? _resultMessage;
  bool _resultIsError = false;

  void _onScanned(String raw) {
    if (_submitting || _pending != null) return;

    try {
      final message = QrMessage.decode(raw);
      switch (message) {
        case TransactionReceiptMessage(:final transaction):
          setState(() => _pending = transaction);
        case PaymentRequestMessage():
          _showError(
            'That is a payment request. Requests are scanned by the PAYER '
            'in the Scan screen.',
          );
      }
    } on FormatException catch (e) {
      _showError(e.message);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message), backgroundColor: Colors.red));
  }

  Future<void> _record() async {
    final tx = _pending;
    if (tx == null || _submitting) return;

    final wallet = context.read<WalletProvider>();
    setState(() => _submitting = true);

    try {
      final isNew = await wallet.recordIncomingPayment(tx);
      if (!mounted) return;
      setState(() {
        _pending = null;
        _resultIsError = false;
        _resultMessage = isNew
            ? 'Recorded ₹${tx.amount.toStringAsFixed(2)} from ${tx.senderId} '
                '(pending sync)'
            : 'Already recorded - duplicate receipt ignored.';
      });
    } on PaymentException catch (e) {
      if (!mounted) return;
      setState(() {
        _pending = null;
        _resultIsError = true;
        _resultMessage = e.reason;
      });
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _cancel() => setState(() => _pending = null);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Incoming Payment')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _pending == null ? _buildScanView() : _buildConfirmView(),
      ),
    );
  }

  Widget _buildScanView() {
    return Column(
      children: [
        if (_resultMessage != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: (_resultIsError ? Colors.red : Colors.green)
                  .withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _resultIsError ? Colors.red : Colors.green),
            ),
            child: Text(
              _resultMessage!,
              style: TextStyle(color: _resultIsError ? Colors.red : Colors.green),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: QrScannerView(
            onValueScanned: _onScanned,
            helpText: 'Scan the receipt QR shown by the payer',
          ),
        ),
      ],
    );
  }

  Widget _buildConfirmView() {
    final tx = _pending!;
    final wallet = context.watch<WalletProvider>();
    final isForMe = tx.receiverId == wallet.currentUser?.userId;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          const Icon(Icons.south_west, size: 72),
          const SizedBox(height: 16),
          Text('Incoming Payment',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _row('From', tx.senderId),
                  const Divider(),
                  _row('Amount', '₹${tx.amount.toStringAsFixed(2)}'),
                  const Divider(),
                  _row('Description', tx.description),
                  const Divider(),
                  _row('Transaction ID', tx.transactionId),
                  const Divider(),
                  _row('Received by', isForMe ? 'your wallet' : 'NOT YOUR WALLET',
                      warn: !isForMe),
                ],
              ),
            ),
          ),
          if (!isForMe) ...[
            const SizedBox(height: 12),
            const Text(
              'This transaction is addressed to another wallet and will be rejected.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.red, fontSize: 13),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: (!isForMe || _submitting) ? null : _record,
            style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Record Payment'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _submitting ? null : _cancel,
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
