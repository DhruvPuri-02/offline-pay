import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/wallet_provider.dart';
import '../utils/payment_exception.dart';
import 'pin_authorization_screen.dart';
import 'show_transaction_qr_screen.dart';

/// Manual payment path (spec section 15): the payer types WHO and HOW MUCH.
///
/// Contrast with the Scan path: there the RECEIVER puts the amount into
/// their QR and the payer only confirms. Both paths funnel into the same
/// `WalletProvider.createOfflinePayment()`, so the validation, ledger write
/// and status handling exist exactly once.
class PayScreen extends StatefulWidget {
  const PayScreen({super.key});

  @override
  State<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends State<PayScreen> {
  final _recipientController = TextEditingController();
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _submitting = false;

  @override
  void dispose() {
    _recipientController.dispose();
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _continue() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final wallet = context.read<WalletProvider>();
    final recipient = _recipientController.text.trim();
    final amount = double.parse(_amountController.text);

    // Show what is about to happen before anything is written.
    final confirmed = await _showConfirmationDialog(wallet, recipient, amount);
    if (confirmed != true || !mounted) return;

    setState(() => _submitting = true);
    try {
      // Phase 4: the PIN gate sits exactly where the spec puts it - after
      // confirmation, before the transaction exists. `onAttempt` runs the
      // payment; the screen handles PIN entry, lockout and error display.
      final tx = await PinAuthorizationScreen.open(
        context,
        summary: {
          'To': recipient,
          'Amount': '₹${amount.toStringAsFixed(2)}',
        },
        onAttempt: (pin) => wallet.createOfflinePayment(
          receiverId: recipient,
          receiverWalletId: recipient, // wallet ID works too; backend sync resolves both
          amount: amount,
          description: _descriptionController.text.trim().isEmpty
              ? 'Payment'
              : _descriptionController.text.trim(),
          transactionPin: pin,
        ),
      );
      if (tx == null || !mounted) return;

      // Replace so "back" from the QR screen goes Home, not back to the
      // filled-in form (which would risk re-submitting the same payment).
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ShowTransactionQRScreen(transaction: tx),
        ),
      );
    } on PaymentException catch (e) {
      // Normally handled inside the PIN screen; kept as a safety net so
      // a rare escaped error still reaches the user visibly.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.reason),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<bool?> _showConfirmationDialog(
    WalletProvider wallet,
    String recipient,
    double amount,
  ) {
    final after = wallet.availableBalance - amount;
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm payment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('To: $recipient'),
            const SizedBox(height: 8),
            Text('Amount: ₹${amount.toStringAsFixed(2)}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Available now: ₹${wallet.availableBalance.toStringAsFixed(2)}'),
            Text('Available after: ₹${after.toStringAsFixed(2)}'),
            const SizedBox(height: 12),
            const Text(
              'The transaction will be saved as PENDING SYNC and shown as a QR for the receiver to scan.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create payment'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pay')),
      body: Consumer<WalletProvider>(
        builder: (context, wallet, _) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Available balance context - the number that actually
                  // matters for whether this payment can go through.
                  Card(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Available offline'),
                          Text(
                            '₹${wallet.availableBalance.toStringAsFixed(2)}',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _recipientController,
                    decoration: const InputDecoration(
                      labelText: 'Recipient (USER_… or WALLET_…)',
                      border: OutlineInputBorder(),
                      hintText: 'e.g. WALLET_abc123',
                    ),
                    validator: (value) {
                      final v = value?.trim() ?? '';
                      if (v.isEmpty) return 'Enter a recipient ID';
                      if (v == wallet.currentUser?.userId ||
                          v == wallet.currentUser?.walletId) {
                        return 'You cannot pay yourself';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _amountController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Amount',
                      prefixText: '₹ ',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final amount = double.tryParse(value ?? '');
                      if (amount == null || amount <= 0) {
                        return 'Enter a valid amount';
                      }
                      if (amount > WalletProvider.maxOfflineTransactionAmount) {
                        return 'Offline limit is ₹'
                            '${WalletProvider.maxOfflineTransactionAmount
                                .toStringAsFixed(0)} per transaction';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),

                  TextFormField(
                    controller: _descriptionController,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),

                  FilledButton(
                    onPressed: _submitting ? null : _continue,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.all(16),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Continue'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan their QR instead'),
                    onPressed: () => Navigator.pushNamed(context, '/scan'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
