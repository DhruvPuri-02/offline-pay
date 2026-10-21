import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/wallet_provider.dart';
import '../services/pin_service.dart';
import '../utils/payment_exception.dart';

/// PIN management for this device (Phase 4).
///
/// Shows the current state (not set / set / locked out) and lets the user
/// create or change the transaction PIN. Changing requires the current
/// PIN - otherwise anyone holding the unlocked phone could silently swap
/// it. There is deliberately no "clear PIN" button: removing the payment
/// control would defeat its purpose.
class PinSettingsScreen extends StatefulWidget {
  const PinSettingsScreen({super.key});

  @override
  State<PinSettingsScreen> createState() => _PinSettingsScreenState();
}

class _PinSettingsScreenState extends State<PinSettingsScreen> {
  final _currentPin = TextEditingController();
  final _newPin = TextEditingController();
  final _confirmPin = TextEditingController();

  bool _showSetForm = false;
  bool _showChangeForm = false;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  Timer? _lockTicker;

  @override
  void initState() {
    super.initState();
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
    _currentPin.dispose();
    _newPin.dispose();
    _confirmPin.dispose();
    super.dispose();
  }

  void _setMessage(String text, {required bool isError}) {
    setState(() {
      _message = text;
      _messageIsError = isError;
    });
  }

  Future<void> _setNewPin() async {
    if (_busy) return;
    final wallet = context.read<WalletProvider>();
    final pin = _newPin.text;

    final formatError = PinService.validateFormat(pin);
    if (formatError != null) return _setMessage(formatError, isError: true);
    if (pin != _confirmPin.text) {
      return _setMessage('PINs do not match.', isError: true);
    }

    setState(() => _busy = true);
    try {
      await wallet.setTransactionPin(pin);
      _newPin.clear();
      _confirmPin.clear();
      setState(() => _showSetForm = false);
      _setMessage('Transaction PIN set.', isError: false);
    } on PaymentException catch (e) {
      _setMessage(e.reason, isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePin() async {
    if (_busy) return;
    final wallet = context.read<WalletProvider>();
    final current = _currentPin.text;
    final updated = _newPin.text;

    final formatError = PinService.validateFormat(updated);
    if (formatError != null) return _setMessage(formatError, isError: true);
    if (updated != _confirmPin.text) {
      return _setMessage('PINs do not match.', isError: true);
    }

    setState(() => _busy = true);
    try {
      // Verifies the current PIN (and honours any active lockout) before
      // anything is replaced.
      await wallet.changeTransactionPin(currentPin: current, newPin: updated);
      _currentPin.clear();
      _newPin.clear();
      _confirmPin.clear();
      setState(() => _showChangeForm = false);
      _setMessage('Transaction PIN changed.', isError: false);
    } on PaymentException catch (e) {
      _setMessage(e.reason, isError: true);
      _currentPin.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wallet = context.watch<WalletProvider>();
    final locked = wallet.pinLockRemaining > Duration.zero;

    return Scaffold(
      appBar: AppBar(title: const Text('Transaction PIN')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---------------------------------------------------------
            // Status
            // ---------------------------------------------------------
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: ListTile(
                leading: Icon(
                  locked
                      ? Icons.timer
                      : wallet.hasTransactionPin
                          ? Icons.pin
                          : Icons.pin_outlined,
                  color: locked
                      ? Colors.red
                      : wallet.hasTransactionPin
                          ? Colors.green
                          : Colors.grey,
                ),
                title: Text(
                  locked
                      ? 'Locked (${wallet.pinLockRemaining.inSeconds}s left)'
                      : wallet.hasTransactionPin
                          ? 'PIN is set'
                          : 'No PIN yet',
                ),
                subtitle: Text(
                  locked
                      ? 'Too many failed attempts.'
                      : wallet.hasTransactionPin
                          ? 'Required before every outgoing payment.'
                          : 'You will create one on your first payment.',
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'This is a PAYMENT PIN, not an app lock: OfflinePay opens without any prompt. '
              'It is stored as a salted bcrypt hash on this device only.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 20),

            if (_message != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (_messageIsError ? Colors.red : Colors.green)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _messageIsError ? Colors.red : Colors.green,
                  ),
                ),
                child: Text(
                  _message!,
                  style: TextStyle(
                    color: _messageIsError ? Colors.red : Colors.green,
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],

            // ---------------------------------------------------------
            // Actions / forms
            // ---------------------------------------------------------
            if (!wallet.hasTransactionPin && !_showSetForm) ...[
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Set PIN now'),
                onPressed:
                    _busy ? null : () => setState(() => _showSetForm = true),
              ),
            ],

            if (_showSetForm) ...[
              _pinField(_newPin, 'New PIN'),
              const SizedBox(height: 12),
              _pinField(_confirmPin, 'Confirm new PIN'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _setNewPin,
                child: const Text('Save PIN'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _showSetForm = false;
                          _newPin.clear();
                          _confirmPin.clear();
                        }),
                child: const Text('Cancel'),
              ),
            ],

            if (wallet.hasTransactionPin && !_showChangeForm) ...[
              OutlinedButton.icon(
                icon: const Icon(Icons.password),
                label: const Text('Change PIN'),
                onPressed: _busy || locked
                    ? null
                    : () => setState(() => _showChangeForm = true),
              ),
            ],

            if (_showChangeForm) ...[
              _pinField(_currentPin, 'Current PIN'),
              const SizedBox(height: 12),
              _pinField(_newPin, 'New PIN'),
              const SizedBox(height: 12),
              _pinField(_confirmPin, 'Confirm new PIN'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _changePin,
                child: const Text('Change PIN'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _showChangeForm = false;
                          _currentPin.clear();
                          _newPin.clear();
                          _confirmPin.clear();
                        }),
                child: const Text('Cancel'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pinField(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      obscureText: true,
      enableSuggestions: false,
      autocorrect: false,
      keyboardType: TextInputType.number,
      maxLength: PinService.maxPinLength,
      enabled: !_busy,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        counterText: '',
      ),
    );
  }
}
