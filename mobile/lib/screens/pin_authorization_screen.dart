import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/wallet_provider.dart';
import '../services/pin_service.dart';
import '../utils/payment_exception.dart';

/// The gate every outgoing payment passes through (spec section 5):
///
///   amount -> confirm -> **enter transaction PIN** -> verify -> create
///
/// One screen serves two jobs:
///  * **setup mode** - no PIN exists yet (first payment ever): the user
///    creates a 4-6 digit PIN, confirmed twice, which is hashed and
///    stored before the payment proceeds
///  * **verify mode** - the PIN is checked against the stored bcrypt hash
///
/// The actual verification happens inside `onAttempt` (which calls
/// `createOfflinePayment(transactionPin: ...)`), so a payment can never
/// be created by bypassing this screen. Wrong PINs and lockouts surface
/// here with their reasons and attempt counters.
class PinAuthorizationScreen extends StatefulWidget {
  const PinAuthorizationScreen({
    super.key,
    required this.onAttempt,
    this.summary = const {},
  });

  /// Performs the payment with the entered PIN. Called only after the
  /// PIN format is sane (and, in setup mode, after the PIN is stored).
  final Future<Transaction> Function(String pin) onAttempt;

  /// What is being authorized, e.g. {Amount: '₹100', To: 'WALLET_bob'}.
  final Map<String, String> summary;

  /// Push the screen; returns the created transaction, or `null` if the
  /// user backed out.
  static Future<Transaction?> open(
    BuildContext context, {
    required Future<Transaction> Function(String pin) onAttempt,
    Map<String, String> summary = const {},
  }) {
    return Navigator.push<Transaction>(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => PinAuthorizationScreen(
          onAttempt: onAttempt,
          summary: summary,
        ),
      ),
    );
  }

  @override
  State<PinAuthorizationScreen> createState() => _PinAuthorizationScreenState();
}

class _PinAuthorizationScreenState extends State<PinAuthorizationScreen> {
  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();

  /// True until a PIN has been stored this session (setup vs verify UI).
  late bool _setupMode;
  bool _busy = false;
  String? _error;
  Timer? _lockTicker;

  @override
  void initState() {
    super.initState();
    _setupMode = !context.read<WalletProvider>().hasTransactionPin;

    // One tick per second keeps the lockout countdown honest even when
    // the provider itself is silent (it only notifies on state changes).
    _lockTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (context.read<WalletProvider>().pinLockRemaining > Duration.zero) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _lockTicker?.cancel();
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _fail(String reason) {
    if (!mounted) return;
    setState(() {
      _error = reason;
      _pinController.clear();
      _confirmController.clear();
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    final wallet = context.read<WalletProvider>();
    final pin = _pinController.text;

    setState(() => _error = null);

    // ---------------------------------------------------------------
    // Setup mode: create the PIN first, then run the payment with it.
    // Setting the PIN is what makes the very first attempt verifiable.
    // ---------------------------------------------------------------
    if (_setupMode) {
      final formatError = PinService.validateFormat(pin);
      if (formatError != null) return _fail(formatError);
      if (pin != _confirmController.text) {
        return _fail('PINs do not match. Try again.');
      }

      setState(() => _busy = true);
      try {
        await wallet.setTransactionPin(pin);
        if (!mounted) return;
        setState(() => _setupMode = false);
      } on PaymentException catch (e) {
        setState(() => _busy = false);
        return _fail(e.reason);
      }
      // fall through: pay with the PIN that was just created
    }

    setState(() => _busy = true);
    try {
      final tx = await widget.onAttempt(pin);
      if (!mounted) return;
      _pinController.clear();
      _confirmController.clear();
      Navigator.pop(context, tx);
    } on PaymentException catch (e) {
      _fail(e.reason);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletProvider>();
    final lockRemaining = wallet.pinLockRemaining;
    final locked = lockRemaining > Duration.zero;

    return Scaffold(
      appBar: AppBar(
        title: Text(_setupMode ? 'Create Transaction PIN' : 'Enter Transaction PIN'),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: _busy ? null : () => Navigator.pop(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---------------------------------------------------------
            // What the user is authorizing
            // ---------------------------------------------------------
            if (widget.summary.isNotEmpty) ...[
              Card(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: widget.summary.entries
                        .map(
                          (e) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(e.key,
                                    style: const TextStyle(color: Colors.grey)),
                                Flexible(
                                  child: Text(
                                    e.value,
                                    textAlign: TextAlign.end,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],

            Icon(
              _setupMode ? Icons.pin_outlined : Icons.lock_outline,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              _setupMode
                  ? 'Choose a 4-6 digit PIN to approve payments.\nYou will enter it once, now, and before every future payment.'
                  : 'Enter your transaction PIN to approve this payment.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 24),

            // ---------------------------------------------------------
            // Lockout banner
            // ---------------------------------------------------------
            if (locked) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.timer, color: Colors.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Locked. Try again in '
                        '${lockRemaining.inSeconds}s.',
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // ---------------------------------------------------------
            // PIN entry
            // ---------------------------------------------------------
            TextField(
              controller: _pinController,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              keyboardType: TextInputType.number,
              maxLength: PinService.maxPinLength,
              enabled: !locked && !_busy,
              decoration: const InputDecoration(
                labelText: 'Transaction PIN',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
            if (_setupMode) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _confirmController,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                keyboardType: TextInputType.number,
                maxLength: PinService.maxPinLength,
                enabled: !locked && !_busy,
                decoration: const InputDecoration(
                  labelText: 'Confirm PIN',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
            ],

            if (!_setupMode &&
                wallet.hasTransactionPin &&
                !locked &&
                wallet.pinAttemptsRemaining < PinService.maxFailedAttempts) ...[
              const SizedBox(height: 8),
              Text(
                '${wallet.pinAttemptsRemaining} attempt(s) left before lockout',
                style: const TextStyle(color: Colors.orange, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
            ],
            const SizedBox(height: 24),

            FilledButton(
              onPressed: (locked || _busy) ? null : _submit,
              style: FilledButton.styleFrom(padding: const EdgeInsets.all(16)),
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_setupMode ? 'Create PIN & Pay' : 'Authorize Payment'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            const SizedBox(height: 8),
            const Text(
              'This PIN only approves payments. It is stored as a salted bcrypt hash and never sent to the backend.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
