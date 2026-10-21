import 'package:flutter/material.dart';

import '../utils/balance.dart';

/// Home screen balance display.
///
/// Shows all three balances from spec section 10 instead of one number,
/// because the difference between them IS the offline story:
///
///   available  - what you may spend offline right now
///   confirmed  - what the backend has agreed with
///   pending    - offline payments not yet synchronized
class BalanceCard extends StatelessWidget {
  const BalanceCard({super.key, required this.summary});

  final BalanceSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.secondary,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Available Balance',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text(
            '₹${summary.available.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 36,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          const Divider(color: Colors.white30, height: 1),
          const SizedBox(height: 8),
          _detailRow('Confirmed', '₹${summary.confirmed.toStringAsFixed(2)}'),
          _detailRow(
            'Pending out (offline)',
            '-₹${summary.pendingOutgoing.toStringAsFixed(2)}',
          ),
          _detailRow(
            'Pending in (offline)',
            '+₹${summary.pendingIncoming.toStringAsFixed(2)}',
          ),
          const SizedBox(height: 8),
          const Text(
            'Simulated money - not real currency',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
