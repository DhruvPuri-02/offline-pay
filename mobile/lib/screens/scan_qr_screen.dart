import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import '../providers/wallet_provider.dart';
import '../models/qr_payload.dart';
import '../models/transaction.dart';
import '../utils/id_generator.dart';

class ScanQRScreen extends StatefulWidget {
  const ScanQRScreen({super.key});

  @override
  State<ScanQRScreen> createState() => _ScanQRScreenState();
}

class _ScanQRScreenState extends State<ScanQRScreen> {
  final _qrCodeController = TextEditingController();
  bool _isProcessing = false;
  QRPayload? _scannedPayload;

  @override
  void dispose() {
    _qrCodeController.dispose();
    super.dispose();
  }

  void _simulateScan() {
    // For Phase 2 demo - simulate scanning by pasting QR JSON
    if (_qrCodeController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please paste QR code JSON')),
      );
      return;
    }

    try {
      final Map<String, dynamic> qrData = jsonDecode(_qrCodeController.text);
      final qrPayload = QRPayload.fromJson(qrData);

      if (qrPayload.isExpired) {
        _showError('QR code has expired');
        return;
      }

      setState(() {
        _scannedPayload = qrPayload;
      });
    } catch (e) {
      _showError('Invalid QR code format');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _confirmPayment() async {
    if (_scannedPayload == null) return;

    final wallet = context.read<WalletProvider>();
    if (wallet.currentUser == null) return;

    if (_scannedPayload!.receiverId == wallet.currentUser!.userId) {
      _showError('Cannot pay yourself');
      return;
    }

    if (wallet.balance < _scannedPayload!.amount) {
      _showError('Insufficient balance');
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      final transaction = Transaction(
        transactionId: IdGenerator.generateTransactionId(),
        senderId: wallet.currentUser!.userId,
        receiverId: _scannedPayload!.receiverId,
        senderWalletId: wallet.currentUser!.walletId,
        receiverWalletId: _scannedPayload!.receiverWalletId,
        amount: _scannedPayload!.amount,
        type: TransactionType.offlinePayment,
        status: TransactionStatus.confirmed,
        description: _scannedPayload!.description,
        nonce: _scannedPayload!.nonce,
        timestamp: DateTime.now(),
      );

      wallet.updateBalance(wallet.balance - _scannedPayload!.amount);
      wallet.addTransaction(transaction);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Payment of ₹${_scannedPayload!.amount} successful!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      _showError('Payment failed: $e');
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  void _cancelPayment() {
    setState(() {
      _scannedPayload = null;
      _qrCodeController.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: _scannedPayload == null
          ? _buildScanScreen()
          : _buildConfirmationScreen(),
    );
  }

  Widget _buildScanScreen() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const Text('Phase 2 Demo: Paste QR JSON below'),
          const SizedBox(height: 16),
          TextField(
            controller: _qrCodeController,
            maxLines: 8,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Paste QR JSON here',
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _simulateScan,
            child: const Text('Simulate Scan'),
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmationScreen() {
    return Consumer<WalletProvider>(
      builder: (context, wallet, child) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const SizedBox(height: 24),
              const Icon(Icons.qr_code_2, size: 80),
              const SizedBox(height: 24),
              Text('Confirm Payment', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 32),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _buildInfoRow('Pay to', _scannedPayload!.receiverName),
                      const Divider(),
                      _buildInfoRow('Amount', '₹${_scannedPayload!.amount}'),
                      const Divider(),
                      _buildInfoRow('Description', _scannedPayload!.description),
                      const Divider(),
                      _buildInfoRow('Your Balance', '₹${wallet.balance}'),
                      const Divider(),
                      _buildInfoRow('Balance After', '₹${wallet.balance - _scannedPayload!.amount}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isProcessing ? null : _confirmPayment,
                child: _isProcessing ? const CircularProgressIndicator() : const Text('Confirm Payment'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _cancelPayment, child: const Text('Cancel')),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.grey)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    );
  }
}
