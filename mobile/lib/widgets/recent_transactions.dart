import 'package:flutter/material.dart';
import '../models/transaction.dart';
import 'transaction_tile.dart';

class RecentTransactions extends StatelessWidget {
  final List<Transaction> transactions;
  final String currentUserId;

  const RecentTransactions({
    super.key,
    required this.transactions,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    if (transactions.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No transactions yet',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return Column(
      children: transactions
          .map((txn) => TransactionTile(
                transaction: txn,
                currentUserId: currentUserId,
                margin: const EdgeInsets.symmetric(vertical: 4),
              ))
          .toList(),
    );
  }
}
