import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'dart:async';
import 'dart:convert';
import '../providers/wallet_provider.dart';
import '../models/qr_payload.dart';
import '../services/peer/lan_peer.dart';
import '../services/receipt_inbox.dart';
import '../utils/id_generator.dart';

class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  QRPayload? _qrPayload;
  bool _isGenerating = false;

  // Phase 8: the same request shown as a QR can also be SERVED over the
  // local Wi-Fi so a payer fetches it by address instead of scanning.
  // The host lives in this screen's state: it starts when the receiver
  // switches it on and stops when they cancel or leave this screen.
  final LanPeerHost _lanHost = LanPeerHost();
  bool _servingLan = false;
  bool _lanBusy = false;
  String? _lanAddress;

  @override
  void dispose() {
    unawaited(_lanHost.stop());
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  /// Switch handler: start/stop serving the current request over Wi-Fi.
  Future<void> _toggleLan(bool enabled) async {
    final payload = _qrPayload;
    if (payload == null || _lanBusy) return;
    setState(() => _lanBusy = true);
    try {
      if (enabled) {
        // Byte-for-byte the JSON the QR shows - one protocol message,
        // two carriers.
        await _lanHost.start(
          requestJson: jsonEncode(payload.toJson()),
          onReceipt: _onLanReceipt,
        );
        final address = await _lanHost.addressLabel();
        if (!mounted) return;
        setState(() {
          _servingLan = true;
          _lanAddress = address;
        });
      } else {
        await _lanHost.stop();
        if (!mounted) return;
        setState(() {
          _servingLan = false;
          _lanAddress = null;
        });
      }
    } catch (error) {
      await _lanHost.stop();
      if (!mounted) return;
      setState(() {
        _servingLan = false;
        _lanAddress = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not share over Wi-Fi: $error'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _lanBusy = false);
    }
  }

  /// A receipt arrived over the LAN channel: park it in the inbox. It is
  /// NOT recorded here - RecordPaymentScreen runs the same signature
  /// verification and user confirmation as a scanned QR (see
  /// services/receipt_inbox.dart).
  void _onLanReceipt(String receiptJson) {
    ReceiptInbox.instance.add(receiptJson);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Receipt received from a nearby device - open '
          '"I received a payment" to record it.',
        ),
      ),
    );
  }

  void _generateQR() {
    final amount = double.tryParse(_amountController.text);
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid amount')),
      );
      return;
    }

    final wallet = context.read<WalletProvider>();
    if (wallet.currentUser == null) return;

    setState(() {
      _isGenerating = true;
    });

    final qrPayload = QRPayload(
      receiverId: wallet.currentUser!.userId,
      receiverName: wallet.currentUser!.name,
      receiverWalletId: wallet.currentUser!.walletId,
      amount: amount,
      description: _descriptionController.text.isEmpty
          ? 'Payment'
          : _descriptionController.text,
      nonce: IdGenerator.generateNonce(),
    );

    setState(() {
      _qrPayload = qrPayload;
      _isGenerating = false;
    });
  }

  void _clearQR() {
    unawaited(_lanHost.stop());
    setState(() {
      _qrPayload = null;
      _servingLan = false;
      _lanAddress = null;
      _amountController.clear();
      _descriptionController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receive Payment'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_qrPayload == null) ...[
              // Input form
              Text(
                'Generate QR Code',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _amountController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  prefixText: '₹ ',
                  border: OutlineInputBorder(),
                  hintText: 'Enter amount',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description (Optional)',
                  border: OutlineInputBorder(),
                  hintText: 'What is this payment for?',
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isGenerating ? null : _generateQR,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                ),
                child: _isGenerating
                    ? const CircularProgressIndicator()
                    : const Text('Generate QR Code'),
              ),
            ] else ...[
              // QR Code display
              Center(
                child: Column(
                  children: [
                    Text(
                      'Show this QR to receive',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 24),
                    Container(
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
                        data: jsonEncode(_qrPayload!.toJson()),
                        version: QrVersions.auto,
                        size: 280.0,
                        backgroundColor: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            _buildInfoRow('Amount', '₹${_qrPayload!.amount.toStringAsFixed(2)}'),
                            const Divider(),
                            _buildInfoRow('Description', _qrPayload!.description),
                            const Divider(),
                            _buildInfoRow('Expires in', _formatDuration(_qrPayload!.timeUntilExpiry)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Phase 8 alternative carrier: serve the identical
                    // request JSON to a payer on the same Wi-Fi.
                    Card(
                      child: SwitchListTile(
                        secondary: const Icon(Icons.wifi),
                        title: const Text('Also serve via Wi-Fi'),
                        subtitle: Text(
                          _servingLan
                              ? _lanAddress != null
                                  ? 'Address for the payer: $_lanAddress'
                                  : 'Serving - no address found, check Wi-Fi '
                                      'is connected'
                              : 'A nearby phone can fetch this request '
                                  'instead of scanning',
                        ),
                        value: _servingLan,
                        onChanged: _lanBusy ? null : _toggleLan,
                      ),
                    ),
                    if (_servingLan && _lanAddress != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'On the payer phone: Scan → "From a nearby device" '
                        '→ enter that address. They pay offline; the receipt '
                        'travels back and you record it in "I received a '
                        'payment" with the usual verification.',
                        style: TextStyle(
                          color: Colors.blue.shade900,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _clearQR,
                      icon: const Icon(Icons.close),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            // Other side of the handshake: the receiver may also need to
            // book a payment someone else created (scan their receipt QR).
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pushNamed(context, '/record-payment');
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('I received a payment - scan receipt'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.all(16),
              ),
            ),
            const SizedBox(height: 16),
            // Info card
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'The payer will scan this QR code to send you money',
                      style: TextStyle(
                        color: Colors.blue.shade900,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w500,
            color: Colors.grey,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
    }
    return '${duration.inSeconds}s';
  }
}
