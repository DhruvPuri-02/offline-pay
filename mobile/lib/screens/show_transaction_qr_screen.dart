import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/transaction.dart';
import '../models/qr_message.dart';
import '../services/peer/lan_peer.dart';
import '../services/peer/peer_transport.dart';

/// Shown to the PAYER right after an offline payment is created.
///
/// It displays the full transaction as a QR code (message type 2,
/// TRANSACTION_RECEIPT). The receiver scans this to book the incoming
/// payment - which is how the money actually crosses between devices
/// without internet. Until the receiver scans it, only the payer's ledger
/// knows about the transaction.
///
/// Phase 8: when the request was fetched from a receiver's LAN host
/// ([lanTarget]), the receipt can be POSTED back to that same device with
/// one tap instead of a scan. The QR stays visible as the fallback for
/// every failure - sending over LAN is convenience, never a requirement.
class ShowTransactionQRScreen extends StatefulWidget {
  const ShowTransactionQRScreen({
    super.key,
    required this.transaction,
    this.lanTarget,
  });

  final Transaction transaction;

  /// Where to send the receipt back over the LAN channel, or null when
  /// the request arrived by QR scan/paste (no return address exists).
  final LanTarget? lanTarget;

  @override
  State<ShowTransactionQRScreen> createState() => _ShowTransactionQRScreenState();
}

class _ShowTransactionQRScreenState extends State<ShowTransactionQRScreen> {
  bool _sending = false;
  bool _sent = false;

  /// Phase 8 receipt leg: payer -> receiver over the LAN host that served
  /// the request. Best effort - a failure just leaves the QR on screen.
  Future<void> _sendReceipt(LanTarget target) async {
    if (_sending || _sent) return;
    setState(() => _sending = true);
    try {
      await LanPeerClient().sendReceipt(
        target,
        encodeTransactionReceipt(widget.transaction),
      );
      if (!mounted) return;
      setState(() => _sent = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Receipt sent - the receiver records it in '
            '"I received a payment" after verifying it.',
          ),
        ),
      );
    } on PeerTransportException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${e.reason} Show the QR instead.'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final receiptJson = encodeTransactionReceipt(widget.transaction);
    final target = widget.lanTarget;
    final transaction = widget.transaction;

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

            // Phase 8: send the receipt back over the LAN channel the
            // request arrived on (only when there IS one).
            if (target != null) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                icon: _sent ? const Icon(Icons.check) : const Icon(Icons.wifi),
                label: Text(
                  _sent
                      ? 'Receipt sent to $target'
                      : 'Send receipt to $target',
                ),
                onPressed: (_sending || _sent) ? null : () => _sendReceipt(target),
              ),
              const SizedBox(height: 4),
              const Text(
                'Hands the receipt to the receiver\'s phone directly. '
                'They still verify its signature and confirm before it '
                'is recorded - sending is never recording.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],

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
