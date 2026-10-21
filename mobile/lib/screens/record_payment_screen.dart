import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/qr_message.dart';
import '../models/transaction.dart';
import '../providers/wallet_provider.dart';
import '../services/signature_service.dart';
import '../utils/payment_exception.dart';
import '../widgets/qr_scanner_view.dart';

/// What we know about the receipt's signature (Phase 5).
enum _SignatureState { unsigned, valid, invalid }

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
  _SignatureState _signatureState = _SignatureState.unsigned;

  Future<void> _onScanned(String raw) async {
    if (_submitting || _pending != null) return;

    try {
      final message = QrMessage.decode(raw);
      switch (message) {
        case TransactionReceiptMessage(:final transaction):
          // Phase 5: verify BEFORE showing the confirm card, so a
          // tampered receipt is visibly refused instead of quietly
          // failing after the user taps Record.
          final state = await _verifyReceipt(transaction);
          if (!mounted) return;
          setState(() {
            _pending = transaction;
            _signatureState = state;
          });
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

  /// Cryptographic verdict on a scanned receipt (same check the wallet
  /// re-runs at record time - defense in depth, and it costs ~7ms).
  Future<_SignatureState> _verifyReceipt(Transaction tx) async {
    final signature = tx.signature;
    final publicKey = tx.senderPublicKey;
    if (signature == null && publicKey == null) {
      return _SignatureState.unsigned; // pre-Phase-5 build sent this
    }
    if (signature == null || publicKey == null) {
      return _SignatureState.invalid;
    }
    final valid = await SignatureService.verify(
      SignatureService.canonicalPayload(tx),
      signatureBase64: signature,
      publicKeyBase64: publicKey,
    );
    return valid ? _SignatureState.valid : _SignatureState.invalid;
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
          const SizedBox(height: 12),
          _signatureBanner(tx),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: (!isForMe || _submitting) ||
                    _signatureState == _SignatureState.invalid
                ? null
                : _record,
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

  /// Phase 5 verdict, rendered before the user commits to recording.
  Widget _signatureBanner(Transaction tx) {
    final (color, icon, text) = switch (_signatureState) {
      _SignatureState.valid => (
          Colors.green,
          Icons.verified_user,
          'Signature verified - matches payer key ${_fingerprint(tx.senderPublicKey)}',
        ),
      _SignatureState.invalid => (
          Colors.red,
          Icons.gpp_bad,
          'Signature INVALID - this receipt does not match its details '
              '(tampered or forged). Recording is blocked.',
        ),
      _SignatureState.unsigned => (
          Colors.grey,
          Icons.warning_amber,
          'Unsigned receipt (sent by an older app version). It cannot be '
              'cryptographically checked.',
        ),
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  /// Short slice of a base64 public key for display.
  static String _fingerprint(String? publicKeyBase64) {
    if (publicKeyBase64 == null || publicKeyBase64.length < 8) {
      return 'unknown';
    }
    return publicKeyBase64.substring(0, 8);
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
